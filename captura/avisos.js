// =====================================================================
// FAMILY OFFICE · Lectores de avisos bancarios por mail (sin IA)  v1.0
// Lo usan el script de Gmail (captura/gmail.js) y las pruebas locales
// (herramientas/probar-avisos.mjs). Es JavaScript plano, sin módulos,
// porque Google Apps Script no los admite.
//
// Avisos.leer({ de, asunto, html, recibido }) devuelve null si el mail no es
// un aviso de movimiento conocido, o:
// { banco, tipo, monto, moneda, fecha, hora, descripcion, ultimos4, cuenta,
//   cuotas, titular }
// tipo: consumo_tarjeta | transferencia_enviada | transferencia_recibida
// Signos como en movimientos: positivo entra, negativo sale.
//
// Avisos.autentico(crudo, dominios) verifica con los encabezados que agrega
// el servidor que recibió el mail (el primero de arriba) que el remitente
// pasó DMARC, o la cadena ARC si el mail llegó redirigido.
// =====================================================================

var Avisos = (function () {
  var DOMINIOS = ["santander.com.ar", "bbva.com.ar", "macro.com.ar"];

  // ---------- Utilidades ----------
  var ENTIDADES = { nbsp: " ", amp: "&", lt: "<", gt: ">", quot: '"', apos: "'",
    aacute: "á", eacute: "é", iacute: "í", oacute: "ó", uacute: "ú", ntilde: "ñ",
    Aacute: "Á", Eacute: "É", Iacute: "Í", Oacute: "Ó", Uacute: "Ú", Ntilde: "Ñ", uuml: "ü" };

  function textoPlano(html) {
    return String(html || "")
      .replace(/<(style|script|title|head)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<br\s*\/?>|<\/(p|div|tr|td|li|h\d)>/gi, "\n")
      .replace(/<[^>]+>/g, " ")
      .replace(/&#(\d+);/g, function (_, n) { return String.fromCharCode(+n); })
      .replace(/&([a-zA-Z]+);/g, function (m, e) { return ENTIDADES[e] != null ? ENTIDADES[e] : m; })
      .replace(/[ \t\r\f\v]+/g, " ")
      .replace(/\s*\n\s*/g, "\n")
      .trim();
  }

  // "$100.000,00", "U$S 25,50", "USD 1.234,56" → { valor, moneda }
  function importe(s) {
    var m = String(s).match(/(U\$S|USD|US\$|\$)\s*(-?\d{1,3}(?:\.\d{3})*(?:,\d{1,2})?|-?\d+(?:,\d{1,2})?)/i);
    if (!m) return null;
    return { valor: Number(m[2].replace(/\./g, "").replace(",", ".")), moneda: m[1] === "$" ? "ARS" : "USD" };
  }

  function fechaISO(s) {
    var m = String(s || "").match(/(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
    if (!m) return null;
    var y = m[3].length === 2 ? "20" + m[3] : m[3];
    return y + "-" + ("0" + m[2]).slice(-2) + "-" + ("0" + m[1]).slice(-2);
  }

  function fechaLocal(d) {
    if (!d) return null;
    var x = new Date(d.getTime() - 3 * 3600 * 1000);   // hora de Argentina (UTC-3)
    return x.toISOString().slice(0, 10);
  }

  // Valor que sigue a una etiqueta en el texto ("Comercio\nNOMBRE DEL COMERCIO" → "NOMBRE DEL COMERCIO")
  function campo(texto, etiqueta) {
    var re = new RegExp("(?:^|\\n)\\s*" + etiqueta + "\\s*:?\\s*\\n?\\s*([^\\n]+)", "i");
    var m = texto.match(re);
    return m ? m[1].trim() : null;
  }

  function dominioDe(direccion) {
    var m = String(direccion || "").toLowerCase().match(/@([a-z0-9.-]+)/);
    return m ? m[1] : "";
  }
  function bancoDe(dominio) {
    for (var i = 0; i < DOMINIOS.length; i++) {
      var d = DOMINIOS[i];
      if (dominio === d || dominio.slice(-(d.length + 1)) === "." + d) return d;
    }
    return null;
  }

  // ---------- Santander ----------
  // Consumo con tarjeta ("Pagaste $…", "Tu adicional hizo un consumo"): el cuerpo dice
  // "detalle de(l) (tu) consumo … con (la|su|tu) Tarjeta … terminada en NNNN" y sigue
  // con pares etiqueta-valor (Monto, Cuotas, Comercio, Fecha, Hora)
  function santander(t, asunto, recibido) {
    var tarjeta = t.match(/con (?:la|su|tu)\s+(?:Tarjeta\s+)?(.+?)\s+terminada en\s+(\d{4})/i);
    if (/detalle de(?:l| tu) consumo/i.test(t) && tarjeta) {
      var imp = importe(campo(t, "Monto") || "");
      if (!imp) return null;
      var titular = (t.match(/consumo que hizo\s+(.+?)\s+con su/i) || [])[1] || null;
      var cuotas = Number(campo(t, "Cuotas")) || 1;
      return { banco: "Santander", tipo: "consumo_tarjeta", monto: -imp.valor, moneda: imp.moneda,
               fecha: fechaISO(campo(t, "Fecha")) || fechaLocal(recibido), hora: campo(t, "Hora"),
               descripcion: campo(t, "Comercio") || "Consumo", ultimos4: tarjeta[2], cuenta: null,
               cuotas: cuotas, titular: titular, tarjeta: tarjeta[1].replace(/^Santander\s+/i, "") };
    }
    return null;
  }

  var LECTORES = { "santander.com.ar": santander };

  function leer(mail) {
    var banco = bancoDe(dominioDe(mail.de));
    if (!banco || !LECTORES[banco]) return null;
    var t = textoPlano(mail.html);
    var r = LECTORES[banco](t, mail.asunto || "", mail.recibido || null);
    if (r && r.descripcion) r.descripcion = r.descripcion.replace(/\s+/g, " ").trim();
    return r;
  }

  // ---------- Autenticidad ----------
  // Encabezados desplegados (las líneas que empiezan con espacio continúan la anterior)
  function encabezados(crudo) {
    var cab = String(crudo).split(/\r?\n\r?\n/)[0].replace(/\r?\n[ \t]+/g, " ");
    return cab.split(/\r?\n/).map(function (l) {
      var i = l.indexOf(":");
      return { nombre: l.slice(0, i).trim().toLowerCase(), valor: l.slice(i + 1).trim() };
    });
  }

  function autentico(crudo, dominios) {
    dominios = dominios || DOMINIOS;
    var ar = encabezados(crudo).filter(function (h) { return h.nombre === "authentication-results"; })[0];
    if (!ar) return false;
    var v = ar.valor.toLowerCase();
    var permitido = function (d) { return !!d && dominios.some(function (x) { return d === x || d.slice(-(x.length + 1)) === "." + x; }); };
    var dmarc = v.match(/dmarc=pass[^;]*?header\.from=([a-z0-9.-]+)/);
    if (dmarc && permitido(dmarc[1])) return true;
    var arc = v.match(/arc=pass\s*\(([^)]*)\)/);
    if (arc) {
      var dk = arc[1].match(/dkim=pass\s+dkdomain=([a-z0-9.-]+)/);
      var dm = arc[1].match(/dmarc=pass\s+fromdomain=([a-z0-9.-]+)/);
      if ((dk && permitido(dk[1])) || (dm && permitido(dm[1]))) return true;
    }
    return false;
  }

  return { leer: leer, autentico: autentico, textoPlano: textoPlano, DOMINIOS: DOMINIOS };
})();
