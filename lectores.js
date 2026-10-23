// =====================================================================
// FAMILY OFFICE · Lectores de resúmenes (sin IA)  v1.1
// Formatos: Santander cuenta, Visa Santander, Macro cuenta, Visa/Amex Macro,
//           BBVA cuenta, Visa/Mastercard BBVA, Ciudad cuenta, Mercado Pago.
//           Devuelven siempre la misma estructura:
// { documento:{tipo,banco,formato,periodo_desde,periodo_hasta,
//              tarjeta?:{cierre,vencimiento,proximo_cierre,proximo_vencimiento,
//                        pago_minimo,cuotas_proximo_resumen}},
//   cuentas:[{ identificador:{cbu,numero,ultimos4[]}, descripcion, titulares?:{ultimos4: nombre},
//              conciliacion:[{moneda,fecha_inicial,saldo_inicial,fecha_final,saldo_final}],
//              movimientos:[{fecha,descripcion,monto,moneda,tipo_cambio,comprobante,
//                            cuota_nro,cuotas_total,ultimos4}] }] }
// Signos: positivo entra, negativo sale. En tarjetas, la deuda es negativa.
// =====================================================================

// ---------- Utilidades ----------
const RE_MONTO = /^-?\s*(U\$S|\$)?\s*-?\s*\d{1,3}(\.\d{3})*,\d{2}$/;
const esMonto = (s) => RE_MONTO.test(s.trim());

function monto(s) {
  const t = s.trim();
  const neg = t.includes("-");
  const moneda = t.includes("U$S") ? "USD" : "ARS";
  const v = Number(t.replace(/[^\d,]/g, "").replace(",", "."));
  return { v: neg ? -v : v, moneda };
}
const redondo = (n) => Math.round(n * 100) / 100;
const texto = (l) => l.items.map((i) => i.s).join(" ").replace(/\s+/g, " ").trim();
const iso = (d, m, y) => `${String(y).length === 2 ? "20" + y : y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
function ddmmaa(s) {
  const m = s.match(/(\d{1,2})[\/-](\d{1,2})[\/-](\d{2,4})/);
  return m ? iso(m[1], m[2], m[3]) : null;
}
function diaAnterior(f) {
  const d = new Date(f + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}
const MESES = { enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7, agosto: 8,
  septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12 };
const MESES_CORTOS = { ene: 1, jan: 1, feb: 2, mar: 3, abr: 4, apr: 4, may: 5, jun: 6, jul: 7, ago: 8, aug: 8,
  sep: 9, set: 9, oct: 10, nov: 11, dic: 12, dec: 12 };
// "24 Sep 26", "24-Sep-26", "01-SET-2026"
function fechaCorta(s) {
  const m = String(s).match(/(\d{1,2})[\s-]([A-Za-z]{3})[\s-](\d{2,4})/);
  return m && MESES_CORTOS[m[2].toLowerCase()] ? iso(m[1], MESES_CORTOS[m[2].toLowerCase()], m[3]) : null;
}
// Montos de Macro tarjeta ("225.220,74-") y Ciudad ("2863.820,58")
const RE_MONTO_LIBRE = /^-?\d+(\.\d{3})*,\d{2}-?$/;
const esMontoLibre = (s) => RE_MONTO_LIBRE.test(s.trim());
const montoLibre = (s) => { const t = s.trim(); const v = Number(t.replace(/[^\d,]/g, "").replace(",", ".")); return t.includes("-") ? -v : v; };
// Cuota de una compra en cuotas: va con fecha de cierre y la fecha original en la descripción
function marcarCuota(mov, nro, total, cierre) {
  mov.cuota_nro = Number(nro); mov.cuotas_total = Number(total);
  mov.descripcion += ` (compra original ${mov.fecha.split("-").reverse().join("/").replace(/^(\d\d\/\d\d\/)20/, "$1")})`;
  mov.fecha = cierre;
}
const minFecha = (movs, def) => movs.reduce((a, m) => (m.fecha < a ? m.fecha : a), def ?? "9999-12-31");

// Ajusta el signo de cada movimiento con la variación del saldo (columna Saldo)
function signoPorSaldo(movs, saldoInicial) {
  let prev = saldoInicial;
  for (const m of movs) {
    if (m._saldo == null) continue;
    const delta = redondo(m._saldo - prev);
    if (Math.abs(Math.abs(delta) - Math.abs(m.monto)) < 0.005) m.monto = Math.abs(m.monto) * Math.sign(delta || 1);
    prev = m._saldo;
  }
  movs.forEach((m) => delete m._saldo);
}

// ---------- Extracción de líneas con posiciones ----------
export async function extraerLineas(pdfjsLib, data, password) {
  const doc = await pdfjsLib.getDocument({ data, password, useSystemFonts: true }).promise;
  const paginas = [];
  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const tc = await page.getTextContent();
    const items = tc.items
      .filter((i) => i.str.trim() !== "")
      .map((i) => ({ x: i.transform[4], y: i.transform[5], w: i.width, s: i.str }));
    const lineas = [];
    for (const it of items) {
      let l = lineas.find((l) => Math.abs(l.y - it.y) < 2.5);
      if (!l) { l = { y: it.y, pag: p, items: [] }; lineas.push(l); }
      l.items.push(it);
    }
    lineas.sort((a, b) => b.y - a.y);
    lineas.forEach((l) => l.items.sort((a, b) => a.x - b.x));
    paginas.push(lineas);
  }
  return paginas;
}

// ---------- Detección de formato ----------
export function detectarFormato(paginas) {
  const todo = paginas.flat().map(texto).join("\n");
  if (/Resumen Visa/i.test(todo) && /30-50000845-4/.test(todo) && /Tarjetas incluidas/i.test(todo)) return "santander_visa";
  if (/Mi resumen de cuenta/i.test(todo) && /Santander/i.test(todo)) return "santander_cuenta";
  if (/Periodo del Extracto/i.test(todo) && /Banco Macro/i.test(todo)) return "macro_cuenta";
  if (/BBVA/i.test(todo) && /Movimientos en cuentas/i.test(todo)) return "bbva_cuenta";
  if (/RESUMEN DE CUENTA EN/i.test(todo) && /CVU/i.test(todo) && /Mercado (Libre|Pago)/i.test(todo)) return "mercadopago";
  if (/CUIT:\s*30\s*50001008\s*4/.test(todo) && /CIERRE ACTUAL:/.test(todo) && /RESUMEN NRO\./.test(todo)) return "macro_tarjeta";
  if (/BBVA/.test(todo) && /CIERRE ACTUAL/.test(todo) && /VENCIMIENTO ACTUAL/.test(todo)) return "bbva_tarjeta";
  if (/30-99903208-3/.test(todo) && /RESUMEN DE CUENTA/.test(todo) && /SALDO ANTERIOR/.test(todo)) return "ciudad_cuenta";
  return null;
}

export async function leerResumen(pdfjsLib, data, { password, hoy = new Date() } = {}) {
  const paginas = await extraerLineas(pdfjsLib, data, password);
  const formato = detectarFormato(paginas);
  if (!formato) throw new Error("Formato de resumen no reconocido. Tráelo al Proyecto para crear su lector.");
  const lector = { santander_cuenta: santanderCuenta, santander_visa: santanderVisa,
                   macro_cuenta: macroCuenta, macro_tarjeta: macroTarjeta, bbva_cuenta: bbvaCuenta,
                   bbva_tarjeta: bbvaTarjeta, ciudad_cuenta: ciudadCuenta, mercadopago: mercadoPago }[formato];
  const r = lector(paginas, hoy);
  r.documento.formato = formato;
  return r;
}

// =====================================================================
// SANTANDER · Resumen de cuenta
// =====================================================================
function santanderCuenta(paginas) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  const desde = ddmmaa(todo.match(/Desde:\s*([\d\/]+)/)[1]);
  const hasta = ddmmaa(todo.match(/Hasta:\s*([\d\/]+)/)[1]);
  const cbu = (todo.match(/CBU:\s*(\d{22})/) || [])[1] || null;
  const numero = (todo.match(/Cuenta\s+([\d-]+\/\d)/) || [])[1] || null;

  const porMoneda = {};
  let moneda = null, ultimo = null;
  for (const l of lineas) {
    const t = texto(l);
    if (/^(Resumen de tus productos|Detalle impositivo)/i.test(t)) break;
    if (/^Movimientos en pesos/i.test(t)) { moneda = "ARS"; ultimo = null; continue; }
    if (/^Movimientos en d[oó]lares/i.test(t)) { moneda = "USD"; ultimo = null; continue; }
    if (/^No ten[eé]s movimientos/i.test(t)) { moneda = null; ultimo = null; continue; }
    if (!moneda) continue;
    const b = (porMoneda[moneda] ??= { movs: [], ini: null, fin: null });
    const montos = l.items.filter((i) => esMonto(i.s) && i.x >= 330);
    if (/^Saldo total/i.test(t) || l.items.some((i) => /^Saldo total/i.test(i.s))) {
      if (montos.length) b.fin = monto(montos.at(-1).s).v;
      moneda = null; ultimo = null; continue;
    }
    const primero = l.items[0];
    const tieneFecha = primero.x < 60 && /^\d{2}\/\d{2}\/\d{2}$/.test(primero.s);
    if (tieneFecha && /Saldo Inicial/i.test(t)) { b.ini = monto(montos.at(-1).s).v; continue; }
    if (tieneFecha && montos.length >= 2) {
      const comp = l.items.find((i) => i.x > 55 && i.x < 110 && /^\d+$/.test(i.s));
      const desc = l.items.filter((i) => i.x >= 110 && i.x < 330 && !esMonto(i.s)).map((i) => i.s).join(" ");
      const m = monto(montos[0].s);
      ultimo = { fecha: ddmmaa(primero.s), descripcion: desc, monto: m.v, moneda,
                 tipo_cambio: null, comprobante: comp?.s ?? null, cuota_nro: null, cuotas_total: null,
                 ultimos4: null, _saldo: monto(montos.at(-1).s).v };
      b.movs.push(ultimo);
      continue;
    }
    if (!tieneFecha && ultimo && montos.length === 0 && primero.x >= 110 && primero.x < 330) {
      ultimo.descripcion += " " + t;
    }
  }

  // Préstamos: desglose de la cuota (capital, intereses, seguros) y saldo actualizado
  let numPrestamo = null, saldoPrestamo = null;
  for (const l of lineas) {
    const t = texto(l);
    const np = t.match(/^N[uú]mero:\s*(\d+)\s*Saldo:\s*(\$\s*[\d.,]+)/);
    if (np) { numPrestamo = np[1]; saldoPrestamo = monto(np[2]).v; continue; }
    const cu = l.items[0].s.match(/^(\d+) de (\d+)$/);
    const ms = l.items.filter((i) => esMonto(i.s));
    if (cu && ms.length >= 6 && numPrestamo) {
      const [cap, int, seg, imp, otr, tot] = ms.map((i) => monto(i.s).v);
      const mov = Object.values(porMoneda).flatMap((b) => b.movs)
        .find((m) => /prestamo/i.test(m.descripcion) && Math.abs(Math.abs(m.monto) - tot) < 0.005);
      if (mov) {
        mov.cuota_nro = Number(cu[1]); mov.cuotas_total = Number(cu[2]);
        mov.partes = [
          { rubro: "Intereses hipoteca", monto: -int, concepto: `Intereses cuota ${cu[1]}` },
          { rubro: "Amortización hipoteca", monto: -cap, concepto: `Capital cuota ${cu[1]}` },
          { rubro: "Seguro hipoteca", monto: -seg, concepto: `Seguros cuota ${cu[1]}` },
        ].concat(imp || otr ? [{ rubro: "Comisiones bancarias", monto: -(imp + otr), concepto: `Impuestos y otros cuota ${cu[1]}` }] : []);
        mov.prestamo = { numero: numPrestamo, saldo: saldoPrestamo, cuota_actual: Number(cu[1]), fecha: hasta };
      }
    }
  }

  const conciliacion = [], movimientos = [];
  for (const [mon, b] of Object.entries(porMoneda)) {
    if (!b.movs.length && !b.ini && !b.fin) continue;
    signoPorSaldo(b.movs, b.ini ?? 0);
    conciliacion.push({ moneda: mon, fecha_inicial: diaAnterior(desde), saldo_inicial: b.ini ?? 0,
                        fecha_final: hasta, saldo_final: b.fin ?? b.ini ?? 0 });
    movimientos.push(...b.movs);
  }
  return {
    documento: { tipo: "resumen_cuenta", banco: "Santander", periodo_desde: desde, periodo_hasta: hasta },
    cuentas: [{ identificador: { cbu, numero, ultimos4: [] }, descripcion: `Cuenta ${numero ?? ""}`.trim(),
                conciliacion, movimientos }],
  };
}

// =====================================================================
// SANTANDER · Resumen Visa
// =====================================================================
function santanderVisa(paginas) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  const numero = (todo.match(/Cuenta N[ºo°]\s*(\d+)/) || [])[1] || null;

  // Fechas: línea con 6 fechas (cierre ant., vto. ant., cierre act., vto. act., próx. cierre, próx. vto.)
  const lFechas = lineas.find((l) => l.items.filter((i) => /^\d{2}\/\d{2}\/\d{2}$/.test(i.s)).length >= 4);
  const fechas = lFechas.items.filter((i) => /^\d{2}\/\d{2}\/\d{2}$/.test(i.s)).map((i) => ddmmaa(i.s));
  const cierreAnt = fechas[0], cierre = fechas[2];

  const movs = [];
  const ini = { ARS: 0, USD: 0 }, fin = { ARS: null, USD: null };
  const plasticos = new Set();
  let estado = null, fechaActual = null, ultimos4 = null, ultimo = null, baseRG5617 = null;

  for (const l of lineas) {
    const t = texto(l);
    if (/^Pago anterior y devoluciones/i.test(t)) { estado = "pago"; continue; }
    if (/^Saldo del resumen anterior/i.test(t)) { estado = null; continue; }
    const mT = t.match(/terminada en (\d{4})/i);
    if (/^Visa cr[eé]dito terminada en/i.test(t) && mT) { ultimos4 = mT[1]; plasticos.add(ultimos4); estado = "cons"; ultimo = null; continue; }
    if (/^Impuestos, intereses y percepciones/i.test(t)) { ultimos4 = null; estado = "cons"; ultimo = null; continue; }
    const montos = l.items.filter((i) => esMonto(i.s) && i.x >= 360);
    if (/^Total a pagar/i.test(t) && montos.length) {
      for (const it of montos) { const m = monto(it.s); fin[m.moneda] = -m.v; }
      estado = null; continue;
    }
    if (!estado || /^(Fecha|Subtotal|Movimientos de|Copia fiel)/i.test(t)) { if (/^Subtotal/i.test(t)) ultimo = null; continue; }

    const primero = l.items[0];
    if (primero.x < 60 && /^\d{2}\/\d{2}\/\d{2}$/.test(primero.s)) fechaActual = ddmmaa(primero.s);
    const desc = l.items.filter((i) => i.x >= 95 && i.x < 245 && !esMonto(i.s)).map((i) => i.s).join(" ");

    if (estado === "pago") {
      if (/Saldo anterior/i.test(desc)) {
        for (const it of montos) { const m = monto(it.s); ini[m.moneda] = -m.v; }
        continue;
      }
      if (montos.length) {
        const tc = desc.match(/tc\s*([\d.,]+)/i);
        for (const it of montos) {
          const m = monto(it.s);
          movs.push({ fecha: fechaActual, descripcion: desc, monto: -m.v, moneda: m.moneda,
                      tipo_cambio: m.moneda === "USD" && tc ? Number(tc[1].replace(/\.(?=\d{3}(\D|$))/g, "").replace(",", ".")) : null,
                      comprobante: null, cuota_nro: null, cuotas_total: null, ultimos4: null });
        }
      }
      continue;
    }

    // Consumos e impuestos
    if (!montos.length) {
      if (ultimo && primero.x >= 95 && primero.x < 245) ultimo.descripcion += " " + desc;
      continue;
    }
    const cuota = l.items.find((i) => /^\d+ de \d+$/.test(i.s));
    const comp = l.items.find((i) => i.x >= 285 && i.x < 360 && /^\d+$/.test(i.s));
    const m = monto(montos[0].s);
    const rg = desc.match(/rg\s*5617.*\(\s*([\d.,]+)\s*\)/i);
    if (rg) baseRG5617 = Number(rg[1].replace(/\./g, "").replace(",", "."));
    let fecha = fechaActual, descripcion = desc, cuota_nro = null, cuotas_total = null;
    if (cuota) {
      [cuota_nro, cuotas_total] = cuota.s.split(" de ").map(Number);
      descripcion += ` (compra original ${fechaActual.split("-").reverse().join("/").replace(/^(\d\d\/\d\d\/)20/, "$1")})`;
      fecha = cierre;
    }
    ultimo = { fecha, descripcion, monto: -m.v, moneda: m.moneda, tipo_cambio: null,
               comprobante: comp?.s ?? null, cuota_nro, cuotas_total, ultimos4 };
    movs.push(ultimo);
  }

  // Tipo de cambio de consumos en USD a partir de la base de la percepción RG 5617
  const consUSD = movs.filter((m) => m.moneda === "USD" && m.monto < 0);
  const totUSD = -consUSD.reduce((s, m) => s + m.monto, 0);
  if (baseRG5617 && totUSD > 0) consUSD.forEach((m) => (m.tipo_cambio = Math.round((baseRG5617 / totUSD) * 100) / 100));

  const fIni = diaAnterior(minFecha(movs, cierreAnt));
  const conciliacion = ["ARS", "USD"]
    .filter((mon) => ini[mon] || fin[mon] || movs.some((m) => m.moneda === mon))
    .map((mon) => ({ moneda: mon, fecha_inicial: fIni, saldo_inicial: ini[mon], fecha_final: cierre, saldo_final: fin[mon] ?? 0 }));
  return {
    documento: { tipo: "resumen_tarjeta", banco: "Santander", periodo_desde: cierreAnt, periodo_hasta: cierre,
                 tarjeta: { cierre, vencimiento: fechas[3] ?? null, proximo_cierre: fechas[4] ?? null,
                            proximo_vencimiento: fechas[5] ?? null, pago_minimo: null, cuotas_proximo_resumen: null } },
    cuentas: [{ identificador: { cbu: null, numero, ultimos4: [...plasticos] }, descripcion: `Visa ${numero ?? ""}`.trim(),
                conciliacion, movimientos: movs }],
  };
}

// =====================================================================
// MACRO · Resumen de cuentas
// =====================================================================
function macroCuenta(paginas) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  const per = todo.match(/Periodo del Extracto:\s*([\d\/]+)\s*al\s*([\d\/]+)/);
  const desde = ddmmaa(per[1]), hasta = ddmmaa(per[2]);
  const cuentas = [];
  let c = null;
  for (const l of lineas) {
    const t = texto(l);
    const h = t.match(/^(CAJA DE AHORROS|CUENTA SUELDO|CUENTA CORRIENTE).*NRO\.:\s*([\w-]+)/);
    if (h) {
      c = { tipoTxt: h[1], numero: h[2], moneda: /DOLARES/.test(t) ? "USD" : "ARS", cbu: null,
            ini: 0, fIni: null, fin: null, fFin: null, movs: [] };
      cuentas.push(c); continue;
    }
    if (!c) continue;
    const cb = t.match(/Debito Directo:\s*([\d-]+)/);
    if (cb && !c.cbu) { c.cbu = cb[1].replace(/-/g, ""); continue; }
    const montos = l.items.filter((i) => esMonto(i.s) && i.x >= 300);
    const si = t.match(/SALDO ULTIMO EXTRACTO AL ([\d\/]+)/);
    if (si) { c.ini = montos.length ? monto(montos.at(-1).s).v : 0; c.fIni = ddmmaa(si[1]); continue; }
    const sf = t.match(/SALDO FINAL AL DIA ([\d\/]+)/);
    if (sf) { c.fin = montos.length ? monto(montos.at(-1).s).v : 0; c.fFin = ddmmaa(sf[1]); continue; }
    const primero = l.items[0];
    if (primero.x < 60 && /^\d{2}\/\d{2}\/\d{2}$/.test(primero.s) && montos.length >= 2) {
      const ref = l.items.find((i) => i.x >= 255 && i.x < 300);
      const desc = l.items.filter((i) => i.x >= 60 && i.x < 255).map((i) => i.s).join(" ").replace(/\s+/g, " ");
      c.movs.push({ fecha: ddmmaa(primero.s), descripcion: desc, monto: monto(montos[0].s).v, moneda: c.moneda,
                    tipo_cambio: null, comprobante: ref?.s ?? null, cuota_nro: null, cuotas_total: null,
                    ultimos4: null, _saldo: monto(montos.at(-1).s).v });
    }
  }
  const salida = cuentas
    .filter((c) => c.movs.length || c.ini || c.fin)
    .map((c) => {
      signoPorSaldo(c.movs, c.ini);
      return {
        identificador: { cbu: c.cbu, numero: c.numero, ultimos4: [] },
        descripcion: `${c.tipoTxt.toLowerCase().replace(/^./, (x) => x.toUpperCase())} ${c.numero}`,
        conciliacion: [{ moneda: c.moneda, fecha_inicial: c.fIni ?? diaAnterior(desde), saldo_inicial: c.ini,
                         fecha_final: c.fFin ?? hasta, saldo_final: c.fin ?? c.ini }],
        movimientos: c.movs,
      };
    });
  return { documento: { tipo: "resumen_cuenta", banco: "Macro", periodo_desde: desde, periodo_hasta: hasta }, cuentas: salida };
}

// =====================================================================
// BBVA · Resumen de cuentas y paquetes
// =====================================================================
function bbvaCuenta(paginas, hoy) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  // El año no figura en las fechas: se toma del código de sobre (AAAAMM) o de la fecha actual
  const cod = todo.match(/(20\d{2})(0[1-9]|1[0-2])\d{2,3}DIGITAL/);
  const anio = (mes) => {
    if (cod) return Number(cod[1]) + (mes < Number(cod[2]) - 6 ? 1 : 0);
    const y = hoy.getFullYear();
    return mes > hoy.getMonth() + 1 ? y - 1 : y;
  };
  const cbus = {};
  for (let i = 0; i < lineas.length - 1; i++) {
    const t = texto(lineas[i]), n = texto(lineas[i + 1]);
    const a = t.match(/^(CA|CC)\s+(\$|U\$S)\s+([\d\-\/]+)/);
    const b = n.match(/^CBU\s+([\d ]+)/);
    if (a && b) cbus[a[3]] = b[1].replace(/\s/g, "").slice(0, 22);
  }
  const cuentas = [];
  let c = null, detalle = false;
  for (const l of lineas) {
    const t = texto(l);
    if (/^Movimientos en cuentas/i.test(t)) { detalle = true; continue; }
    if (!detalle) continue;
    const h = t.match(/^(CA|CC)\s+(\$|U\$S)\s+([\d\-\/]+)\s*\(([^)]+)\)/);
    if (h) {
      c = { numero: h[3], moneda: h[2] === "U$S" ? "USD" : "ARS", tipoTxt: h[4], cbu: cbus[h[3]] ?? null,
            ini: 0, fin: null, fFin: null, movs: [] };
      cuentas.push(c); continue;
    }
    if (!c) continue;
    const montos = l.items.filter((i) => esMonto(i.s) && i.x >= 340);
    if (/^SALDO ANTERIOR/i.test(t)) { c.ini = monto(montos.at(-1).s).v; continue; }
    const sf = t.match(/^SALDO AL (\d{1,2}) DE ([A-ZÁÉÍÓÚ]+)/i);
    if (sf) {
      const mes = MESES[sf[2].toLowerCase()];
      c.fin = monto(montos.at(-1).s).v; c.fFin = iso(sf[1], mes, anio(mes)); continue;
    }
    if (/^TOTAL MOVIMIENTOS/i.test(t)) { c = null; continue; }
    const primero = l.items[0];
    if (/^\d{2}\/\d{2}$/.test(primero.s) && montos.length >= 2) {
      const [d, m] = primero.s.split("/").map(Number);
      const origen = l.items.find((i) => i.x >= 90 && i.x < 130 && /^\d+$/.test(i.s));
      const desc = l.items.filter((i) => i.x >= 130 && !esMonto(i.s)).map((i) => i.s).join(" ");
      c.movs.push({ fecha: iso(d, m, anio(m)), descripcion: desc, monto: monto(montos[0].s).v, moneda: c.moneda,
                    tipo_cambio: null, comprobante: origen?.s ?? null, cuota_nro: null, cuotas_total: null,
                    ultimos4: null, _saldo: monto(montos.at(-1).s).v });
    }
  }
  const salida = cuentas.filter((c) => c.movs.length || c.ini || c.fin).map((c) => {
    signoPorSaldo(c.movs, c.ini);
    const fFin = c.fFin ?? c.movs.reduce((a, m) => (m.fecha > a ? m.fecha : a), "0000-00-00");
    return {
      identificador: { cbu: c.cbu, numero: c.numero, ultimos4: [] },
      descripcion: `${c.tipoTxt} ${c.numero}`,
      conciliacion: [{ moneda: c.moneda, fecha_inicial: diaAnterior(minFecha(c.movs, fFin)), saldo_inicial: c.ini,
                       fecha_final: fFin, saldo_final: c.fin ?? c.ini }],
      movimientos: c.movs,
    };
  });
  const desde = salida.length ? salida[0].conciliacion[0].fecha_inicial : null;
  const hasta = salida.length ? salida[0].conciliacion[0].fecha_final : null;
  return { documento: { tipo: "resumen_cuenta", banco: "BBVA", periodo_desde: desde, periodo_hasta: hasta }, cuentas: salida };
}

// =====================================================================
// MERCADO PAGO · Resumen de cuenta
// =====================================================================
function mercadoPago(paginas) {
  const todo = paginas.flat().map(texto).join("\n");
  const cvu = (todo.match(/CVU:\s*(\d{22})/) || [])[1] || null;
  const moneda = /RESUMEN DE CUENTA EN D[OÓ]LARES/i.test(todo) ? "USD" : "ARS";
  const per = todo.match(/Del (\d{1,2}) al (\d{1,2}) de ([a-záéíóú]+) de (\d{4})/i);
  const mes = MESES[per[3].toLowerCase()];
  const desde = iso(per[1], mes, per[4]), hasta = iso(per[2], mes, per[4]);
  const ini = monto(todo.match(/Saldo inicial:\s*([-$\d.,\s]+?)(?:\s{1,}Saldo final|\n|$)/i)[1]).v;
  const fin = monto(todo.match(/Saldo final:\s*(\$\s*-?[\d.,]+)/i)[1]).v;

  const movs = [];
  for (const lineas of paginas) {
    const anclas = [], fragmentos = [];
    let enTabla = false;
    for (const l of lineas) {
      const t = texto(l);
      if (/^Fecha Descripci[oó]n/i.test(t)) { enTabla = true; continue; }
      if (/^Fecha de generaci[oó]n/i.test(t)) { enTabla = false; continue; }
      if (!enTabla) continue;
      const primero = l.items[0];
      if (/^\d{2}-\d{2}-\d{4}$/.test(primero.s)) {
        const montos = l.items.filter((i) => esMonto(i.s));
        const id = l.items.find((i) => i.x >= 185 && i.x < 270 && /^\d+$/.test(i.s));
        const a = { y: l.y, fecha: ddmmaa(primero.s), id: id?.s ?? null,
                    monto: monto(montos[0].s).v, saldo: monto(montos.at(-1).s).v, partes: [] };
        const d = l.items.filter((i) => i.x >= 80 && i.x < 185).map((i) => i.s).join(" ");
        if (d) a.partes.push({ y: l.y, s: d });
        anclas.push(a);
      } else if (primero.x >= 80 && primero.x < 185 && !l.items.some((i) => esMonto(i.s))) {
        fragmentos.push({ y: l.y, s: t });
      }
    }
    for (const f of fragmentos) {
      let mejor = null;
      for (const a of anclas) if (!mejor || Math.abs(a.y - f.y) < Math.abs(mejor.y - f.y)) mejor = a;
      if (mejor && Math.abs(mejor.y - f.y) < 14) mejor.partes.push(f);
    }
    for (const a of anclas) {
      movs.push({ fecha: a.fecha, descripcion: a.partes.sort((x, y) => y.y - x.y).map((p) => p.s).join(" "),
                  monto: a.monto, moneda, tipo_cambio: null, comprobante: a.id, cuota_nro: null,
                  cuotas_total: null, ultimos4: null, _saldo: a.saldo });
    }
  }
  signoPorSaldo(movs, ini);
  return {
    documento: { tipo: "resumen_cuenta", banco: "Mercado Pago", periodo_desde: desde, periodo_hasta: hasta },
    cuentas: [{ identificador: { cbu: cvu, numero: null, ultimos4: [] }, descripcion: `CVU ${cvu ?? ""}`.trim(),
                conciliacion: [{ moneda, fecha_inicial: diaAnterior(desde), saldo_inicial: ini, fecha_final: hasta, saldo_final: fin }],
                movimientos: movs }],
  };
}

// =====================================================================
// MACRO · Resumen de tarjeta (Visa y Amex comparten formato)
// Montos con el signo al final ("225.220,74-"); los consumos de cada
// plástico terminan en una línea "Tarjeta NNNN Total Consumos de ...".
// =====================================================================
function macroTarjeta(paginas) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  const numero = (todo.match(/N DE CUENTA:\s*(\d+)/) || [])[1] || null;
  const marca = /American Express/i.test(texto(lineas[0])) ? "Amex" : "Visa";
  const F = "(\\d{2} [A-Za-z]{3} \\d{2})";
  const fecha = (re) => fechaCorta((todo.match(new RegExp(re + "\\s*" + F)) || [])[1] ?? "");
  const cierre = fecha("CIERRE ACTUAL:"), cierreAnt = fecha("CIERRE ANTERIOR");
  const proximoCierre = fecha("PROXIMO CIERRE"), proximoVto = fecha("PROXIMO VTO\\.");

  // Fila bajo "VENCIMIENTO SALDO $ SALDO U$S PAGO MIN.$": vencimiento, saldos y pago mínimo
  const iVto = lineas.findIndex((l) => /VENCIMIENTO/.test(texto(l)) && /SALDO \$/.test(texto(l)));
  const filaVto = lineas[iVto + 1].items;
  const vencimiento = fechaCorta(filaVto.map((i) => i.s).join(" "));
  const valores = filaVto.filter((i) => i.x >= 370 && esMontoLibre(i.s)).map((i) => ({ x: i.x, v: montoLibre(i.s) }));
  const fin = { ARS: -(valores.find((v) => v.x < 410)?.v ?? 0), USD: -(valores.find((v) => v.x >= 410 && v.x < 450)?.v ?? 0) };
  const pagoMinimo = valores.find((v) => v.x >= 450 && v.x < 500)?.v ?? null;

  // Cuotas a vencer: la primera columna es el próximo resumen
  const iCuotas = lineas.findIndex((l) => /^Cuotas a vencer/i.test(texto(l)));
  const cuotaProx = iCuotas >= 0 ? (texto(lineas[iCuotas + 2]).match(/\$\s?(\d[\d.]*,\d{2})/) || [])[1] : null;

  const movs = [], ini = { ARS: 0, USD: 0 }, titulares = {};
  let detalle = false, pendientes = [];
  for (const l of lineas) {
    const t = texto(l);
    if (/^FECHA COMPROBANTE DETALLE/i.test(t)) { detalle = true; continue; }
    if (!detalle) continue;
    if (/^SALDO ACTUAL/i.test(t)) break;
    const montos = l.items.filter((i) => i.x >= 400 && esMontoLibre(i.s));
    if (/^SALDO ANTERIOR/i.test(t)) {
      for (const i of montos) ini[i.x < 490 ? "ARS" : "USD"] = -montoLibre(i.s);
      continue;
    }
    const tot = t.match(/^Tarjeta (\d{4}) Total Consumos de (.+?)(?:\s+[\d.,]+-?)*\s*_?$/i);
    if (tot) {
      titulares[tot[1]] = tot[2].trim();
      pendientes.forEach((m) => (m.ultimos4 = tot[1])); pendientes = []; continue;
    }
    const primero = l.items[0];
    if (!/^\d{2}\.\d{2}\.\d{2}$/.test(primero.s) || !montos.length) continue;
    const comp = l.items.find((i) => i.x >= 100 && i.x < 165);
    const desc = l.items.filter((i) => i.x >= 165 && i.x < 400).map((i) => i.s).join(" ");
    for (const i of montos) {
      const m = { fecha: ddmmaa(primero.s.replace(/\./g, "/")), descripcion: desc, monto: -montoLibre(i.s),
                  moneda: i.x < 490 ? "ARS" : "USD", tipo_cambio: null, comprobante: comp?.s ?? null,
                  cuota_nro: null, cuotas_total: null, ultimos4: null };
      const cu = desc.match(/Cuota (\d{2})\/(\d{2})/i);
      if (cu) marcarCuota(m, cu[1], cu[2], cierre);
      movs.push(m);
      if (m.monto < 0 && !/^(INTERESES|DB IVA|IMPUESTO|PERCEP|IIBB|COMISION)/i.test(desc)) pendientes.push(m);
    }
  }

  const conciliacion = ["ARS", "USD"]
    .filter((mon) => ini[mon] || fin[mon] || movs.some((m) => m.moneda === mon))
    .map((mon) => ({ moneda: mon, fecha_inicial: diaAnterior(minFecha(movs, cierreAnt)), saldo_inicial: ini[mon],
                     fecha_final: cierre, saldo_final: fin[mon] }));
  return {
    documento: { tipo: "resumen_tarjeta", banco: "Macro", periodo_desde: cierreAnt, periodo_hasta: cierre,
                 tarjeta: { cierre, vencimiento, proximo_cierre: proximoCierre, proximo_vencimiento: proximoVto,
                            pago_minimo: pagoMinimo, cuotas_proximo_resumen: cuotaProx ? monto(cuotaProx).v : null } },
    cuentas: [{ identificador: { cbu: null, numero, ultimos4: [...new Set(movs.map((m) => m.ultimos4).filter(Boolean))] },
                descripcion: `${marca} ${numero ?? ""}`.trim(), titulares, conciliacion, movimientos: movs }],
  };
}

// =====================================================================
// BBVA · Resumen de tarjeta (Visa y Mastercard comparten formato)
// Arriba hay un cuadro resumen; los movimientos están después de "DETALLE".
// =====================================================================
function bbvaTarjeta(paginas) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  const cab = todo.match(/^(.+?)\s+cuenta\s+([\d-]+)/m);
  const marca = cab ? cab[1].split(" ")[0] : "Tarjeta";
  const numero = cab ? cab[2] : null;
  const RE_F = /^\d{2}-[A-Za-z]{3}-\d{2}$/;
  const fechasDe = (l) => l.items.filter((i) => RE_F.test(i.s)).map((i) => fechaCorta(i.s));

  // Fila de cierre actual, vencimiento, saldos y pago mínimo
  const iAct = lineas.findIndex((l) => /CIERRE ACTUAL/.test(texto(l)) && /VENCIMIENTO ACTUAL/.test(texto(l)));
  const filaAct = lineas[iAct + 1];
  const [cierre, vencimiento] = fechasDe(filaAct);
  const valores = filaAct.items.filter((i) => esMonto(i.s)).map((i) => ({ x: i.x, v: monto(i.s).v }));
  const fin = { ARS: -(valores.find((v) => v.x < 390)?.v ?? 0), USD: -(valores.find((v) => v.x >= 390 && v.x < 490)?.v ?? 0) };
  const pagoMinimo = valores.find((v) => v.x >= 490)?.v ?? null;

  // Otros períodos: cierre y vencimiento anterior, próximo cierre y vencimiento
  const iOtros = lineas.findIndex((l) => /CIERRE ANTERIOR/.test(texto(l)));
  const filaOtros = lineas.slice(iOtros + 1, iOtros + 4).find((l) => fechasDe(l).length >= 4);
  const [cierreAnt, , proximoCierre, proximoVto] = filaOtros ? fechasDe(filaOtros) : [];

  // Total de cuotas a vencer: la primera columna es el próximo resumen
  const iCuotas = lineas.findIndex((l) => /^Total de cuotas a vencer/i.test(texto(l)));
  const cuotaProx = iCuotas >= 0 ? (texto(lineas[iCuotas + 1]).match(/\$\s?(\d[\d.]*,\d{2})/) || [])[1] : null;

  const ini = { ARS: 0, USD: 0 }, movs = [];
  let detalle = false;
  for (const l of lineas) {
    const t = texto(l);
    const montos = l.items.filter((i) => i.x >= 440 && esMonto(i.s));
    if (!detalle) {
      if (/^SALDO ANTERIOR/i.test(t)) for (const i of montos) ini[i.x < 520 ? "ARS" : "USD"] = -monto(i.s).v;
      if (/^DETALLE$/.test(t)) detalle = true;
      continue;
    }
    if (/^Legales y avisos/i.test(t)) break;
    const primero = l.items[0];
    if (!RE_F.test(primero.s) || !montos.length) continue;
    const desc = l.items.filter((i) => i.x >= 110 && i.x < 375).map((i) => i.s).join(" ");
    const cupon = l.items.find((i) => i.x >= 375 && i.x < 440);
    for (const i of montos) {
      const m = { fecha: fechaCorta(primero.s), descripcion: desc, monto: -monto(i.s).v, moneda: i.x < 520 ? "ARS" : "USD",
                  tipo_cambio: null, comprobante: cupon?.s ?? null, cuota_nro: null, cuotas_total: null, ultimos4: null };
      const cu = desc.match(/C\.(\d{2})\/(\d{2})/);
      if (cu) marcarCuota(m, cu[1], cu[2], cierre);
      movs.push(m);
    }
  }

  const conciliacion = ["ARS", "USD"]
    .filter((mon) => ini[mon] || fin[mon] || movs.some((m) => m.moneda === mon))
    .map((mon) => ({ moneda: mon, fecha_inicial: diaAnterior(minFecha(movs, cierreAnt)), saldo_inicial: ini[mon],
                     fecha_final: cierre, saldo_final: fin[mon] }));
  return {
    documento: { tipo: "resumen_tarjeta", banco: "BBVA", periodo_desde: cierreAnt ?? null, periodo_hasta: cierre,
                 tarjeta: { cierre, vencimiento, proximo_cierre: proximoCierre ?? null, proximo_vencimiento: proximoVto ?? null,
                            pago_minimo: pagoMinimo, cuotas_proximo_resumen: cuotaProx ? monto(cuotaProx).v : null } },
    cuentas: [{ identificador: { cbu: null, numero, ultimos4: [] }, descripcion: `${marca} ${numero ?? ""}`.trim(),
                conciliacion, movimientos: movs }],
  };
}

// =====================================================================
// CIUDAD · Resumen de cuenta
// Los millones vienen sin el primer separador ("2863.820,58").
// =====================================================================
function ciudadCuenta(paginas) {
  const lineas = paginas.flat();
  const todo = lineas.map(texto).join("\n");
  const lCbu = lineas.find((l) => l.items.some((i) => i.s === "CBU"));
  const cbu = lCbu ? lCbu.items.filter((i) => i.x > 380).map((i) => i.s).join("").replace(/\D/g, "") || null : null;
  const numero = (todo.match(/CUENTA N\s*[ÚU]\s*MERO\s+([\d\/]+)/) || [])[1] || null;
  const moneda = /SISTEMA CUENTA.*D[OÓ]LAR/.test(todo) ? "USD" : "ARS";

  let ini = 0, fin = null, hasta = null;
  const movs = [];
  for (const l of lineas) {
    const t = texto(l);
    const montos = l.items.filter((i) => i.x >= 150 && i.x < 370 && esMontoLibre(i.s));
    if (/SALDO ANTERIOR/.test(t)) { const m = l.items.filter((i) => esMontoLibre(i.s)).at(-1); if (m) ini = montoLibre(m.s); continue; }
    const sf = t.match(/^SALDO AL (\d{2}\/\d{2}\/\d{4})/);
    if (sf) { hasta = ddmmaa(sf[1]); fin = montoLibre(l.items.filter((i) => esMontoLibre(i.s)).at(-1).s); continue; }
    const primero = l.items[0];
    if (!/^\d{2}-[A-Z]{3}-\d{4}$/.test(primero.s) || montos.length < 2) continue;
    const concepto = l.items.filter((i) => i.x >= 80 && i.x < montos[0].x).map((i) => i.s).join(" ");
    const detalle = l.items.filter((i) => i.x >= 370).map((i) => i.s).join(" ");
    movs.push({ fecha: fechaCorta(primero.s), descripcion: [concepto, detalle].filter(Boolean).join(" · "),
                monto: montoLibre(montos[0].s), moneda, tipo_cambio: null, comprobante: null, cuota_nro: null,
                cuotas_total: null, ultimos4: null, _saldo: montoLibre(montos.at(-1).s) });
  }
  signoPorSaldo(movs, ini);
  hasta ??= movs.reduce((a, m) => (m.fecha > a ? m.fecha : a), "0000-00-00");
  const desde = minFecha(movs, hasta.slice(0, 8) + "01");
  return {
    documento: { tipo: "resumen_cuenta", banco: "Ciudad", periodo_desde: desde, periodo_hasta: hasta },
    cuentas: [{ identificador: { cbu, numero, ultimos4: [] }, descripcion: `Cuenta ${numero ?? ""}`.trim(),
                conciliacion: [{ moneda, fecha_inicial: diaAnterior(desde), saldo_inicial: ini, fecha_final: hasta, saldo_final: fin ?? ini }],
                movimientos: movs }],
  };
}
