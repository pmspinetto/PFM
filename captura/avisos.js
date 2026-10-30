// =====================================================================
// FAMILY OFFICE · Lectores de avisos bancarios por mail (sin IA)  v1.0
// Lo usan el script de Gmail (captura/gmail.js) y las pruebas locales
// (herramientas/probar-avisos.mjs). Es JavaScript plano, sin módulos,
// porque Google Apps Script no los admite.
//
// Avisos.leer({ de, asunto, html, recibido }) devuelve null si el mail no es
// un aviso de movimiento conocido, o:
// { banco, tipo, monto, moneda, fecha, hora, descripcion, ultimos4, cuenta,
//   cuotas, titular, destinatario, cbu, comprobante, reenviado }
// Si el mail lo reenvió a mano una casilla propia, el banco sale del encabezado del
// reenvío que queda en el cuerpo ("De: … <…@santander.com.ar>").
// tipo: consumo_tarjeta | transferencia_enviada | transferencia_recibida
// Signos como en movimientos: positivo entra, negativo sale.
//
// Avisos.autentico(crudo, { dominios, redirectores }) verifica con los encabezados
// que agrega el servidor que recibió el mail (el primero de arriba) que el remitente
// pasó DMARC o la cadena ARC. Si el aviso llegó redirigido por una regla de Hotmail/
// Outlook (que rompe la firma del banco), exige que Gmail haya verificado que lo
// envió una de las casillas de `redirectores` y que Microsoft, al recibirlo en esa
// casilla, haya registrado DMARC aprobado para el dominio del banco.
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

  // Texto entre dos etiquetas (valores que ocupan varias líneas)
  function entre(texto, desde, hasta) {
    var m = texto.match(new RegExp("(?:^|\\n)\\s*" + desde + "\\s*\\n([\\s\\S]*?)\\n\\s*" + hasta + "\\s*(?:\\n|$)", "i"));
    return m ? m[1].replace(/\s+/g, " ").trim() : null;
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
    // Transferencia enviada ("Aviso de transferencia"): pares etiqueta-valor Destinatario,
    // Cuenta de origen ("Cuenta en Pesos XXX-XXX 1234"), CBU de Destino, Importe y Número de
    // comprobante. No trae fecha: se usa la del mail.
    if (/Informaci[oó]n sobre tu transferencia/i.test(t) && /Cuenta de origen/i.test(t)) {
      var origen = entre(t, "Cuenta de origen", "CBU de Destino") || "";
      var impT = importe(entre(t, "Importe", "N[uú]mero de comprobante") || "");
      if (!impT) return null;
      var destinatario = campo(t, "Destinatario");
      var cbu = (campo(t, "CBU de Destino") || "").replace(/\D/g, "");
      return { banco: "Santander", tipo: "transferencia_enviada", monto: -impT.valor,
               moneda: /d[oó]lar/i.test(origen) ? "USD" : impT.moneda,
               fecha: fechaLocal(recibido), hora: null,
               descripcion: "Transferencia a " + (destinatario || "CBU " + cbu),
               ultimos4: null, cuenta: (origen.match(/(\d{3,})\s*$/) || [])[1] || null,
               cuotas: 1, titular: null, destinatario: destinatario, cbu: cbu || null,
               comprobante: (campo(t, "N[uú]mero de comprobante") || "").replace(/\D/g, "") || null };
    }
    return null;
  }

  var LECTORES = { "santander.com.ar": santander };

  // Remitente original de un mail reenviado a mano: la primera línea "De:" / "From:" del cuerpo
  // con la dirección de un banco conocido
  function remitenteReenviado(texto) {
    var re = /(?:^|\n)\s*\*?(?:De|From)\s*:?\*?\s*([^\n]*?@[a-z0-9.-]+[^\n]*)/gi, m;
    while ((m = re.exec(texto))) {
      if (bancoDe(dominioDe(m[1]))) return m[1].trim();
    }
    return null;
  }

  function leer(mail) {
    var t = textoPlano(mail.html);
    var de = mail.de, reenviado = false;
    if (!bancoDe(dominioDe(de))) {
      de = remitenteReenviado(t);
      reenviado = !!de;
    }
    var banco = bancoDe(dominioDe(de));
    if (!banco || !LECTORES[banco]) return null;
    var r = LECTORES[banco](t, mail.asunto || "", mail.recibido || null);
    if (r && r.descripcion) r.descripcion = r.descripcion.replace(/\s+/g, " ").trim();
    if (r && reenviado) { r.reenviado = true; r.remitente_original = de; }
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

  function autentico(crudo, opciones) {
    opciones = opciones || {};
    var dominios = opciones.dominios || DOMINIOS;
    var redirectores = (opciones.redirectores || []).map(function (x) { return String(x).trim().toLowerCase(); }).filter(Boolean);
    var resultados = encabezados(crudo).filter(function (h) { return h.nombre === "authentication-results"; });
    if (!resultados.length) return false;
    var v = resultados[0].valor.toLowerCase();
    var permitido = function (d) { return !!d && dominios.some(function (x) { return d === x || d.slice(-(x.length + 1)) === "." + x; }); };
    var dmarc = v.match(/dmarc=pass[^;]*?header\.from=([a-z0-9.-]+)/);
    if (dmarc && permitido(dmarc[1])) return true;

    // Redirigido por una regla de Outlook desde una casilla propia
    var origen = v.match(/spf=pass[^;]*?smtp\.mailfrom=([^\s;]+)/);
    var firmaMs = /dkim=pass[^;]*?header\.i=@(hotmail|outlook|live)\.com/.test(v);
    if (origen && firmaMs && redirectores.indexOf(origen[1]) >= 0 && resultados[1]) {
      var ms = resultados[1].valor.toLowerCase();
      var dm = ms.match(/^mx\.microsoft\.com\b[\s\S]*?dmarc=pass[^;]*?header\.from=([a-z0-9.-]+)/);
      if (dm && permitido(dm[1])) return true;
    }
    // Reenviado a mano desde una casilla propia: el encabezado From es esa casilla y Gmail verificó
    // SPF, DKIM y DMARC de su dominio (la firma del banco no viaja en un reenvío)
    if (opciones.reenvioManual && origen && redirectores.indexOf(origen[1]) >= 0) {
      var dom = origen[1].split("@")[1];
      var desde = (encabezados(crudo).filter(function (h) { return h.nombre === "from"; })[0] || {}).valor || "";
      if (redirectores.indexOf((desde.toLowerCase().match(/[a-z0-9._%+-]+@[a-z0-9.-]+/) || [])[0]) >= 0 &&
          new RegExp("dkim=pass[^;]*?header\\.(?:i=@|d=)" + dom.replace(/\./g, "\\.")).test(v) &&
          new RegExp("dmarc=pass[^;]*?header\\.from=" + dom.replace(/\./g, "\\.")).test(v)) return true;
    }
    var arc = v.match(/arc=pass\s*\(([^)]*)\)/);
    if (arc) {
      var dk = arc[1].match(/dkim=pass\s+dkdomain=([a-z0-9.-]+)/);
      var dm = arc[1].match(/dmarc=pass\s+fromdomain=([a-z0-9.-]+)/);
      if ((dk && permitido(dk[1])) || (dm && permitido(dm[1]))) return true;
    }
    return false;
  }

  return { leer: leer, autentico: autentico, textoPlano: textoPlano, dominioDe: dominioDe, bancoDe: bancoDe, DOMINIOS: DOMINIOS };
})();
