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
// Además, una vez por día registra el dólar (oficial, MEP, blue y tarjeta) de dolarapi.com;
// esa llamada diaria también mantiene activo el proyecto gratuito de Supabase.
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
  var n = llamar(cfg, obtenerToken(), "rpc/registrar_tipos_cambio", { p: { cotizaciones: cotizaciones } });
  props.setProperty("DOLAR_DIA", hoy);
  console.log("Cotizaciones del dólar registradas hoy: " + n);
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
