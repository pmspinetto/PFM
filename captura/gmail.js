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
// =====================================================================

var ETIQUETAS = ["fo/registrado", "fo/sospechoso", "fo/error"];

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
  var hilos = GmailApp.search("(" + remitentes + ") newer_than:" + dias + "d", 0, 100);

  var token = null, nuevoUltimo = ultimo, primerError = null;
  hilos.forEach(function (hilo) {
    hilo.getMessages().forEach(function (msg) {
      if (msg.getDate() < desdeFecha) return;
      if (msg.getDate() > nuevoUltimo) nuevoUltimo = msg.getDate();
      var etiqueta = null;
      try {
        var aviso = Avisos.leer({ de: msg.getFrom(), asunto: msg.getSubject(), html: msg.getBody(), recibido: msg.getDate() });
        if (!aviso) return;                       // publicidad u otro mail del banco
        if (!Avisos.autentico(msg.getRawContent())) {
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
  // Si algo falló, la próxima vez se vuelve a intentar desde ese mail
  props.setProperty("ULTIMO", (primerError ? new Date(primerError.getTime() - 1000) : nuevoUltimo).toISOString());
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
