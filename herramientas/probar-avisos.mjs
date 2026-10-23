// Prueba los lectores de avisos (captura/avisos.js) contra los .eml de privado/muestras/mails.
// Uso: npm run probar-avisos   (V=1 para ver el texto extraído)
import fs from "fs"; import path from "path";
const Avisos = new Function(fs.readFileSync("captura/avisos.js", "utf8") + "\nreturn Avisos;")();
const dir = "privado/muestras/mails";

// Lector mínimo de .eml: encabezados y la parte text/html decodificada (lo que da Gmail con getBody())
function parsear(crudo) {
  const [cab, ...resto] = crudo.split(/\r?\n\r?\n/);
  const h = {}; cab.replace(/\r?\n[ \t]+/g, " ").split(/\r?\n/).forEach((l) => { const i = l.indexOf(":"); h[l.slice(0, i).toLowerCase()] ??= l.slice(i + 1).trim(); });
  return { h, cuerpo: resto.join("\n\n") };
}
function decodificar(cuerpo, enc, charset) {
  const cs = /8859|latin/i.test(charset || "") ? "latin1" : "utf8";
  if (/quoted-printable/i.test(enc)) {
    const bytes = Buffer.from(cuerpo.replace(/=\r?\n/g, "").replace(/=([0-9A-F]{2})/gi, (_, x) => String.fromCharCode(parseInt(x, 16))), "latin1");
    return bytes.toString(cs);
  }
  if (/base64/i.test(enc)) return Buffer.from(cuerpo.replace(/\s/g, ""), "base64").toString(cs);
  return cuerpo;
}
function html(crudo) {
  const { h, cuerpo } = parsear(crudo);
  const tipo = h["content-type"] || "";
  const b = tipo.match(/boundary="?([^";]+)"?/);
  if (!b) return /html/i.test(tipo) ? decodificar(cuerpo, h["content-transfer-encoding"], (tipo.match(/charset="?([^";]+)/i) || [])[1]) : null;
  for (const parte of cuerpo.split("--" + b[1])) {
    const r = html(parte.replace(/^\r?\n/, ""));
    if (r) return r;
  }
  return null;
}

let fallas = 0;
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".eml")).sort()) {
  const crudo = fs.readFileSync(path.join(dir, f), "utf8");
  const { h } = parsear(crudo);
  const mail = { de: h.from, asunto: h.subject, html: html(crudo), recibido: new Date(h.date) };
  // Casilla que redirige avisos: se toma del propio mail (encabezado Resent-From) para no escribirla acá
  const redirector = (h["resent-from"] || "").replace(/[<>\s]/g, "").toLowerCase();
  const r = Avisos.leer(mail), ok = Avisos.autentico(crudo, { redirectores: redirector ? [redirector] : [] });
  if (!r || !ok) fallas++;
  console.log(`\n${f}\n  auténtico: ${ok}\n  aviso: ${JSON.stringify(r)}`);
  if (process.env.V) console.log(Avisos.textoPlano(mail.html));
}
console.log(fallas ? `\n${fallas} sin leer o sin verificar` : "\nTodos leídos y verificados");
process.exit(fallas ? 1 : 0);
