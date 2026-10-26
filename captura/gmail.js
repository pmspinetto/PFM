// =====================================================================
// FAMILY OFFICE · Captura de avisos bancarios desde Gmail (Google Apps Script)
// Va en un proyecto de Apps Script de la casilla dedicada, junto con avisos.js.
// Cada 10 minutos busca avisos nuevos de los bancos, verifica que sean auténticos,
// los lee y los registra en Supabase con el usuario de captura (que solo puede
// registrar avisos). Gmail agrupa avisos con el mismo asunto en una conversación,
// así que se procesa mail por mail desde el último visto (propiedad ULTIMO); si
// alguno se repite, Supabase lo ignora (message_id único). Las etiquetas son solo
// informativas: fo/registrado · fo/sospechoso (no pasó la verificación) · fo/error
//
// Propiedades del script (Configuración del proyecto → Propiedades del script):
//   SUPABASE_URL, SUPABASE_ANON_KEY, CAPTURA_EMAIL, CAPTURA_CLAVE
//   REDIRECTORES (opcional): casillas propias que redirigen avisos con una regla de
//   Outlook/Hotmail, separadas por coma
// Si se configura AVISAR_A (mail donde recibir alertas), manda por mail las alertas nuevas de
// Family Office (gasto grande, vencimientos, liquidez, pagos duplicados o faltantes).
// Además, una vez por día registra el dólar (oficial, MEP, blue y tarjeta) de dolarapi.com
// y el valor UVA del BCRA;
// esa llamada diaria también mantiene activo el proyecto gratuito de Supabase.
// =====================================================================

// Los resúmenes que llegan con el PDF adjunto se suben a la carpeta privada "bandeja" de
// Supabase y quedan en la bandeja de Importar (etiqueta fo/bandeja).

var ETIQUETAS = ["fo/registrado", "fo/sospechoso", "fo/error", "fo/bandeja"];

function procesarAvisos() {
  var props = PropertiesService.getScriptProperties();
  var cfg = props.getProperties();
  ["SUPABASE_URL", "SUPABASE_ANON_KEY", "CAPTURA_EMAIL", "CAPTURA_CLAVE"].forEach(function (k) {
    if (!cfg[k]) throw new Error("Falta la propiedad del script " + k);
  });
  var etiquetas = {};
  ETIQUETAS.forEach(function (n) { etiquetas[n] = GmailApp.getUserLabelByName(n) || GmailApp.createLabel(n); });

  // Desde el último mail visto, con una hora de margen (la primera vez, 30 días)
  var ultimo = cfg.ULTIMO ? new Date(cfg.ULTIMO) : new Date(Date.now() - 30 * 86400000);
  var desdeFecha = new Date(ultimo.getTime() - 3600000);
  var dias = Math.max(1, Math.ceil((Date.now() - desdeFecha.getTime()) / 86400000));
  var remitentes = Avisos.DOMINIOS.map(function (d) { return "from:" + d; }).join(" OR ");
  // in:anywhere incluye Spam (los avisos redirigidos desde Hotmail a veces caen ahí); se excluye la papelera
  var hilos = GmailApp.search("in:anywhere -in:trash (" + remitentes + ") newer_than:" + dias + "d", 0, 100);

  var token = null, nuevoUltimo = ultimo, primerError = null, revisados = 0, avisos = 0;
  hilos.forEach(function (hilo) {
    hilo.getMessages().forEach(function (msg) {
      if (msg.getDate() < desdeFecha) return;
      if (msg.getDate() > nuevoUltimo) nuevoUltimo = msg.getDate();
      revisados++;
      var etiqueta = null;
      try {
        var pdfs = msg.getAttachments().filter(function (a) {
          return a.getContentType() === "application/pdf" || /\.pdf$/i.test(a.getName());
        });
        if (pdfs.length) {
          if (!Avisos.autentico(msg.getRawContent(), { redirectores: (cfg.REDIRECTORES || "").split(",") })) {
            etiqueta = "fo/sospechoso";
            console.warn("Adjunto de un remitente que no pasó la verificación: " + msg.getSubject());
            return;
          }
          token = token || ingresar(cfg);
          pdfs.forEach(function (a) { subirABandeja(cfg, token, msg, a); });
          etiqueta = "fo/bandeja";
          return;
        }
        var aviso = Avisos.leer({ de: msg.getFrom(), asunto: msg.getSubject(), html: msg.getBody(), recibido: msg.getDate() });
        if (!aviso) return;                       // publicidad u otro mail del banco
        avisos++;
        if (!Avisos.autentico(msg.getRawContent(), { redirectores: (cfg.REDIRECTORES || "").split(",") })) {
          etiqueta = "fo/sospechoso";
          console.warn("No pasó la verificación: " + msg.getSubject() + " (" + msg.getFrom() + ")");
          return;
        }
        token = token || ingresar(cfg);
        var r = llamar(cfg, token, "rpc/registrar_aviso", {
          p: { message_id: msg.getId(), remitente: msg.getFrom(), asunto: msg.getSubject(),
               recibido: msg.getDate().toISOString(), aviso: aviso },
        });
        etiqueta = "fo/registrado";
        console.log(msg.getSubject() + " → " + JSON.stringify(r));
      } catch (e) {
        etiqueta = "fo/error";
        if (!primerError || msg.getDate() < primerError) primerError = msg.getDate();
        console.error(msg.getSubject() + ": " + e.message);
      } finally {
        if (etiqueta) hilo.addLabel(etiquetas[etiqueta]);
      }
    });
  });
  console.log("Mails de bancos revisados desde " + desdeFecha.toISOString() + ": " + revisados +
              ". Avisos de movimientos reconocidos: " + avisos + ".");
  try {
    actualizarDolar(cfg, props, function () { return (token = token || ingresar(cfg)); }, false);
  } catch (e) {
    console.error("Dólar: " + e.message);
  }
  try {
    if (cfg.AVISAR_A) enviarAlertas(cfg, function () { return (token = token || ingresar(cfg)); });
  } catch (e) {
    console.error("Alertas: " + e.message);
  }
  // Si algo falló, la próxima vez se vuelve a intentar desde ese mail
  props.setProperty("ULTIMO", (primerError ? new Date(primerError.getTime() - 1000) : nuevoUltimo).toISOString());
}

// Una vez por día, desde las 18 h de Argentina (o cuando se fuerza): cotizaciones del día.
// Aunque la fuente falle, la llamada a Supabase se hace igual y sirve de latido.
function actualizarDolar(cfg, props, obtenerToken, forzar) {
  var ahora = new Date(Date.now() - 3 * 3600000);   // hora de Argentina
  var hoy = ahora.toISOString().slice(0, 10);
  if (!forzar && (props.getProperty("DOLAR_DIA") === hoy || ahora.getUTCHours() < 18)) return;
  var cotizaciones = [];
  try {
    var r = UrlFetchApp.fetch("https://dolarapi.com/v1/dolares", { muteHttpExceptions: true });
    if (r.getResponseCode() !== 200) throw new Error("respuesta " + r.getResponseCode());
    var tipos = { oficial: "oficial", blue: "blue", bolsa: "mep", tarjeta: "tarjeta" };
    JSON.parse(r.getContentText()).forEach(function (d) {
      if (tipos[d.casa] && d.venta) cotizaciones.push({ fecha: hoy, tipo: tipos[d.casa], compra: d.compra, venta: d.venta });
    });
  } catch (e) {
    console.warn("No se pudo leer el dólar: " + e.message);
  }
  try {
    var u = UrlFetchApp.fetch("https://api.bcra.gob.ar/estadisticas/v4.0/monetarias/31?desde=" + hoy + "&hasta=" + hoy,
                              { muteHttpExceptions: true });
    var detalle = u.getResponseCode() === 200 ? (JSON.parse(u.getContentText()).results[0] || {}).detalle || [] : [];
    if (detalle.length) cotizaciones.push({ fecha: hoy, tipo: "uva", venta: detalle[0].valor });
    else console.warn("No se pudo leer el valor UVA (respuesta " + u.getResponseCode() + ")");
  } catch (e) {
    console.warn("No se pudo leer el valor UVA: " + e.message);
  }
  var n = llamar(cfg, obtenerToken(), "rpc/registrar_tipos_cambio", { p: { cotizaciones: cotizaciones } });
  props.setProperty("DOLAR_DIA", hoy);
  console.log("Cotizaciones registradas hoy (dólar y UVA): " + n);
}

// Sube un PDF adjunto a la carpeta privada "bandeja" y lo registra (si ya estaba, no lo repite)
function subirABandeja(cfg, token, msg, adjunto) {
  var bytes = adjunto.getBytes();
  var hash = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, bytes)
    .map(function (b) { return ("0" + (b & 0xff).toString(16)).slice(-2); }).join("");
  var ruta = hash + ".pdf";
  var r = UrlFetchApp.fetch(cfg.SUPABASE_URL + "/storage/v1/object/bandeja/" + ruta, {
    method: "post", contentType: "application/pdf", payload: bytes, muteHttpExceptions: true,
    headers: { apikey: cfg.SUPABASE_ANON_KEY, Authorization: "Bearer " + token },
  });
  if (r.getResponseCode() >= 300 && !/already exists|Duplicate/i.test(r.getContentText())) {
    throw new Error("No se pudo subir " + adjunto.getName() + ": " + r.getContentText());
  }
  var res = llamar(cfg, token, "rpc/registrar_bandeja", {
    p: { hash: hash, archivo_path: ruta, nombre: adjunto.getName(), remitente: msg.getFrom(),
         asunto: msg.getSubject(), recibido: msg.getDate().toISOString() },
  });
  console.log("Resumen a la bandeja: " + adjunto.getName() + " → " + JSON.stringify(res));
}

// Alertas nuevas por mail (cada alerta se manda una sola vez)
function enviarAlertas(cfg, obtenerToken) {
  var alertas = llamar(cfg, obtenerToken(), "rpc/alertas_por_enviar", {}) || [];
  if (!alertas.length) return;
  var plata = function (a) {
    if (a.monto == null || a.tipo === "saldo_insuficiente") return "";
    var n = Math.abs(Number(a.monto)).toLocaleString("es-AR", { maximumFractionDigits: 0 });
    return " · " + (a.moneda === "USD" ? "US$ " : "$ ") + n;
  };
  var html = "<p>Family Office tiene " + alertas.length + (alertas.length === 1 ? " alerta nueva" : " alertas nuevas") + ":</p><ul>" +
    alertas.map(function (a) {
      return "<li>" + escaparHtml(a.titulo) + plata(a) + (a.detalle ? " <i>(" + escaparHtml(a.detalle) + ")</i>" : "") + "</li>";
    }).join("") + "</ul><p><a href=\"https://pmspinetto.github.io/PFM/\">Abrir Family Office</a></p>";
  MailApp.sendEmail({ to: cfg.AVISAR_A, subject: "Family Office: " + alertas.length + (alertas.length === 1 ? " alerta" : " alertas"), htmlBody: html });
  console.log("Alertas enviadas por mail: " + alertas.length);
}

function escaparHtml(t) {
  return String(t == null ? "" : t).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; });
}

// Ejecutar a mano para probar: registra el dólar del día sin esperar a las 18 h
function probarDolar() {
  var props = PropertiesService.getScriptProperties(), cfg = props.getProperties(), token = null;
  actualizarDolar(cfg, props, function () { return (token = token || ingresar(cfg)); }, true);
}

// Inicia sesión con el usuario de captura y devuelve el token de acceso
function ingresar(cfg) {
  var r = UrlFetchApp.fetch(cfg.SUPABASE_URL + "/auth/v1/token?grant_type=password", {
    method: "post", contentType: "application/json", muteHttpExceptions: true,
    headers: { apikey: cfg.SUPABASE_ANON_KEY },
    payload: JSON.stringify({ email: cfg.CAPTURA_EMAIL, password: cfg.CAPTURA_CLAVE }),
  });
  if (r.getResponseCode() !== 200) throw new Error("No se pudo iniciar sesión en Supabase: " + r.getContentText());
  return JSON.parse(r.getContentText()).access_token;
}

function llamar(cfg, token, ruta, cuerpo) {
  var r = UrlFetchApp.fetch(cfg.SUPABASE_URL + "/rest/v1/" + ruta, {
    method: "post", contentType: "application/json", muteHttpExceptions: true,
    headers: { apikey: cfg.SUPABASE_ANON_KEY, Authorization: "Bearer " + token },
    payload: JSON.stringify(cuerpo),
  });
  if (r.getResponseCode() >= 300) throw new Error(r.getContentText());
  return JSON.parse(r.getContentText() || "null");
}

// Ejecutar una vez: programa procesarAvisos cada 10 minutos
function instalar() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === "procesarAvisos") ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger("procesarAvisos").timeBased().everyMinutes(10).create();
  procesarAvisos();
}

// Prueba la conexión sin registrar nada: inicia sesión y llama a registrar_aviso con un
// aviso vacío. Si el usuario es capturador, Supabase responde "Aviso incompleto".
function probarConexion() {
  var cfg = PropertiesService.getScriptProperties().getProperties();
  var token = ingresar(cfg);
  console.log("Inicio de sesión correcto.");
  try {
    llamar(cfg, token, "rpc/registrar_aviso", { p: {} });
  } catch (e) {
    if (/Aviso incompleto/.test(e.message)) return console.log("Todo listo: el usuario de captura tiene permiso para registrar avisos.");
    if (/No autorizado/.test(e.message)) return console.error("Falta agregar el usuario a capturadores (el insert del SQL Editor).");
    throw e;
  }
}
