// Prueba los lectores contra los PDFs de privado/muestras y verifica la conciliación.
// Uso: npm install pdfjs-dist@4.10.38  &&  node herramientas/probar-lectores.mjs [V=1 para detalle]
import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";
import fs from "fs"; import path from "path";
import { leerResumen } from "../lectores.js";
const dir = "privado/muestras";
let fallas = 0;
const pdfs = fs.readdirSync(dir, { recursive: true }).filter((x) => x.toLowerCase().endsWith(".pdf")).sort();
for (const f of pdfs) {
  try {
    const r = await leerResumen(pdfjs, new Uint8Array(fs.readFileSync(path.join(dir, f))));
    console.log(`\n${f} → ${r.documento.formato} (${r.documento.periodo_desde} a ${r.documento.periodo_hasta})`);
    if (r.documento.tarjeta) console.log("  vencimientos:", JSON.stringify(r.documento.tarjeta));
    for (const c of r.cuentas) for (const k of c.conciliacion) {
      const suma = c.movimientos.filter((m) => m.moneda === k.moneda).reduce((s, m) => s + m.monto, 0);
      const dif = Math.round((k.saldo_inicial + suma - k.saldo_final) * 100) / 100;
      if (dif) fallas++;
      console.log(`  ${c.descripcion} ${k.moneda}: ${c.movimientos.length} movs, diferencia ${dif}`);
      if (process.env.V) c.movimientos.forEach((m) => console.log(`    ${m.fecha} ${m.moneda} ${m.monto} | ${m.descripcion}`));
    }
  } catch (e) { fallas++; console.log(`\n${f} → ERROR: ${e.message}`); }
}
console.log(fallas ? `\n${fallas} problemas` : "\nTodo concilia");
process.exit(fallas ? 1 : 0);
