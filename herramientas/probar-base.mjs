// Prueba las funciones de la base (guardar_importacion, registrar_aviso) en un Postgres local
// (PGlite), con el esquema de privado/sql/01_schema.sql (solo la estructura) + 03 + las migraciones.
// No usa datos reales: crea cuentas y movimientos de prueba. Uso: npm run probar-base
import fs from "fs";
import { PGlite } from "@electric-sql/pglite";
const R = "./";
const db = new PGlite();
const run = (sql) => db.exec(sql);
await run(`create role authenticated; create role anon; create schema auth;
  create table auth.users (id uuid primary key, email text);
  create function auth.uid() returns uuid language sql as $$ select '00000000-0000-0000-0000-000000000001'::uuid $$;`);
await run(fs.readFileSync(R + "privado/sql/01_schema.sql", "utf8").split("\n").slice(0, 352).join("\n"));
const imp = fs.readFileSync(R + "privado/sql/03_importador.sql", "utf8").split("\n");
await run(imp.slice(0, 26).join("\n").replace(/^update prestamos.*$/m, ""));
for (const f of fs.readdirSync(R + "supabase/migrations").filter((x) => x.endsWith(".sql")).sort())
  await run(fs.readFileSync(R + "supabase/migrations/" + f, "utf8"));
await run(`create or replace function es_autorizado() returns boolean language sql as $$ select true $$;
  insert into personas (nombre, tipo) values ('P', 'titular');
  insert into instituciones (nombre, tipo) values ('Banco', 'banco');
  insert into cuentas (alias, persona_id, institucion_id, tipo, moneda) values
    ('Banco $', 1, 1, 'caja_ahorro', 'ARS'), ('Visa', 1, 1, 'tarjeta_credito', 'BIMONEDA'), ('Otra visa', 1, 1, 'tarjeta_credito', 'BIMONEDA');
  insert into rubros (nombre, tipo) values ('Neutros', 'neutro');
  insert into rubros (nombre, padre_id, tipo) values ('Pago de tarjeta', 1, 'neutro'), ('Transferencia interna', 1, 'neutro'), ('Movimiento de efectivo', 1, 'neutro');
  insert into cuentas (alias, persona_id, tipo, moneda) values ('Caja $', 1, 'caja_efectivo', 'ARS');
  insert into rubros (nombre, tipo) values ('Varios', 'gasto');
  insert into rubros (nombre, padre_id, tipo) select 'Efectivo no identificado', id, 'gasto' from rubros where nombre = 'Varios';`);
const R2 = 2;  // rubro Pago de tarjeta
const guardar = async (p) => (await db.query("select guardar_importacion($1::jsonb) as r", [JSON.stringify(p)])).rows[0].r;
const mov = (fecha, desc, monto, moneda, id, tc = null) => ({ fecha, descripcion_original: desc, monto, moneda, tipo_cambio: tc, rubro_id: R2, id_externo: id, confianza: "confirmado" });
const doc = (tipo, d, h, hash) => ({ tipo, periodo_desde: d, periodo_hasta: h, hash });
const pares = async () => (await db.query(`select s.monto as salida, e.monto as entrada, e.moneda, c.alias
  from transferencias_internas t join movimientos s on s.id = t.mov_salida_id left join movimientos e on e.id = t.mov_entrada_id
  left join cuentas c on c.id = e.cuenta_id order by t.id`)).rows;

// A) Pago nuevo: el banco debita 1.030.000,00 y la tarjeta muestra pesos + dólares a tc 1500
console.log("A banco:", await guardar({ cuenta_id: 1, documento: doc("resumen_cuenta", "2026-10-01", "2026-10-31", "a1"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-09-30", saldo_inicial: 5000000, fecha_final: "2026-10-31", saldo_final: 3970000 }],
  movimientos: [mov("2026-10-04", "Pago tarjeta de credito visa", -1030000, "ARS", "b1")] }));
console.log("A tarjeta:", await guardar({ cuenta_id: 2, documento: doc("resumen_tarjeta", "2026-09-26", "2026-10-24", "a2"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-09-25", saldo_inicial: -1000000, fecha_final: "2026-10-24", saldo_final: 0 },
              { moneda: "USD", fecha_inicial: "2026-09-25", saldo_inicial: -20, fecha_final: "2026-10-24", saldo_final: 0 }],
  movimientos: [mov("2026-10-04", "Su pago en pesos", 1000000, "ARS", "t1"), mov("2026-10-04", "Su pago en pesos (dolares, tc 1500)", 20, "USD", "t2", 1500)] }));
console.table(await pares());

// B) Caso septiembre: el débito ya estaba emparejado solo con la parte en pesos
await run(`delete from transferencias_internas; delete from movimientos; delete from saldos; delete from documentos;`);
await run(`insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, tipo_cambio, rubro_id, origen, estado_conciliacion) values
  (1, '2026-09-04', 'Pago visa', -1030000, 'ARS', null, ${R2}, 'resumen', 'conciliado'),
  (2, '2026-09-04', 'Su pago (pesos)', 1000000, 'ARS', null, ${R2}, 'resumen', 'conciliado'),
  (2, '2026-09-04', 'Su pago (dolares tc 1500)', 20, 'USD', 1500, ${R2}, 'resumen', 'pendiente'),
  (3, '2026-09-05', 'Otra tarjeta, mismo importe en USD', 20, 'USD', 1500, ${R2}, 'resumen', 'pendiente');
  insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo)
  select s.id, e.id, 'pago_tarjeta' from movimientos s, movimientos e where s.monto < 0 and e.descripcion_original = 'Su pago (pesos)';`);
console.log("B otra importación:", await guardar({ cuenta_id: 3, documento: doc("resumen_tarjeta", "2026-09-01", "2026-09-30", "b9"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-08-31", saldo_inicial: 0, fecha_final: "2026-09-30", saldo_final: 0 }], movimientos: [] }));
console.table(await pares());
console.log("pendientes:", (await db.query("select descripcion_original, estado_conciliacion from movimientos where estado_conciliacion = 'pendiente'")).rows);

// C) Un importe en dólares que no cierra no se empareja
await run(`delete from transferencias_internas; delete from movimientos;
  insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, tipo_cambio, rubro_id, origen) values
  (1, '2026-09-04', 'Pago visa', -50000, 'ARS', null, ${R2}, 'resumen'), (2, '2026-09-04', 'Su pago dolares', 20, 'USD', 1500, ${R2}, 'resumen');
  insert into transferencias_internas (mov_salida_id, tipo) select id, 'pago_tarjeta' from movimientos where monto < 0;`);
await guardar({ cuenta_id: 3, documento: doc("resumen_tarjeta", "2026-09-01", "2026-09-30", "c9"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-08-31", saldo_inicial: 0, fecha_final: "2026-09-30", saldo_final: 0 }], movimientos: [] });
console.table(await pares());

// D) Captura por mail: aviso registrado y luego absorbido por el resumen
await run(`delete from transferencias_internas; delete from movimientos; delete from saldos; delete from documentos;
  insert into plasticos (cuenta_id, persona_id, ultimos4) values (2, 1, '9999');
  insert into reglas (prioridad, patron, modo, rubro_id) values (50, '%colectivo%', 'auto', ${R2 + 1});`);
const reg = async (id, monto, desc, fecha, cuotas = 1) => (await db.query("select registrar_aviso($1::jsonb) as r", [JSON.stringify({ message_id: id, remitente: "x", asunto: "x", recibido: fecha + "T12:00:00Z",
  aviso: { banco: "Banco", tipo: "consumo_tarjeta", monto, moneda: "ARS", fecha, descripcion: desc, ultimos4: "9999", cuotas } })])).rows[0].r;
console.log("D aviso 1:", await reg("m1", -1500.5, "COLECTIVO 60", "2026-10-22"));
console.log("D aviso 1 repetido:", await reg("m1", -1500.5, "COLECTIVO 60", "2026-10-22"));
console.log("D aviso en 3 cuotas:", await reg("m2", -30000, "TIENDA", "2026-10-10", 3));
console.log("D aviso sin tarjeta:", (await db.query("select registrar_aviso($1::jsonb) as r", [JSON.stringify({ message_id: "m3", aviso: { banco: "Banco", tipo: "consumo_tarjeta", monto: -5, moneda: "ARS", ultimos4: "0000" } })])).rows[0].r);
console.table((await db.query("select fecha, descripcion_original, monto, origen, rubro_id, cuota_nro, cuotas_total from movimientos order by id")).rows);
console.log("D resumen:", await guardar({ cuenta_id: 2, documento: doc("resumen_tarjeta", "2026-09-26", "2026-10-24", "d1"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-09-25", saldo_inicial: 0, fecha_final: "2026-10-24", saldo_final: -11500.5 }],
  movimientos: [mov("2026-10-21", "COLECTIVO SESENTA", -1500.5, "ARS", "r1"), mov("2026-10-24", "TIENDA C.01/03 (compra original 10/10/26)", -10000, "ARS", "r2")] }));
console.table((await db.query("select fecha, descripcion_original, monto, origen from movimientos order by id")).rows);
console.table((await db.query("select message_id, estado, movimiento_id is not null as con_mov from avisos order by id")).rows);

// E) Efectivo: retiro de cajero → caja; arqueos con diferencia
await run(`delete from transferencias_internas; delete from movimientos; delete from saldos; delete from documentos; delete from arqueos;`);
const EF = 4;  // rubro Movimiento de efectivo
console.log("E banco con retiro:", await guardar({ cuenta_id: 1, documento: doc("resumen_cuenta", "2026-10-01", "2026-10-31", "e1"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-09-30", saldo_inicial: 100000, fecha_final: "2026-10-31", saldo_final: 50000 }],
  movimientos: [{ ...mov("2026-10-10", "Extraccion cajero", -50000, "ARS", "x1"), rubro_id: EF }] }));
console.table((await db.query(`select c.alias, m.monto, m.descripcion_original, m.estado_conciliacion from movimientos m join cuentas c on c.id = m.cuenta_id order by m.id`)).rows);
console.log("pares efectivo:", (await db.query("select count(*)::int as n from transferencias_internas where mov_entrada_id is not null")).rows[0].n);
const arqueo = async (contado, fecha) => (await db.query("select registrar_arqueo(4, $1::date, $2) as r", [fecha, contado])).rows[0].r;
console.log("E primer arqueo:", await arqueo(50000, "2026-10-11"));
await run(`insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, origen, estado_conciliacion) values (4, '2026-10-15', 'Verdulería', -10000, 'ARS', 'manual', 'no_aplica')`);
console.log("E segundo arqueo:", await arqueo(35000, "2026-10-20"));
console.log("E caja en vivo:", (await db.query("select saldo_estimado, fuente from v_saldo_vivo where cuenta_id = 4")).rows[0]);

// S) Saldo informado del home banking y control de lo que falta explicar
await run(`insert into saldos (cuenta_id, fecha, moneda, saldo, fuente) values (1, '2026-11-05', 'ARS', 80000, 'informado');
  insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, origen) values (1, '2026-11-02', 'Aviso por mail', -5000, 'ARS', 'mail');`);
console.log("S control:", (await db.query("select resumen_al, saldo_resumen, saldo_esperado, saldo_informado, sin_explicar from v_saldos_control where cuenta_id = 1")).rows[0]);
console.log("S en vivo:", (await db.query("select confirmado_al, saldo_estimado, fuente from v_saldo_vivo where cuenta_id = 1")).rows[0]);
console.log("S resumen del mismo día:", await guardar({ cuenta_id: 1, documento: doc("resumen_cuenta", "2026-11-01", "2026-11-05", "s2"),
  conciliar: [{ moneda: "ARS", fecha_inicial: "2026-10-31", saldo_inicial: 50000, fecha_final: "2026-11-05", saldo_final: 79000 }],
  movimientos: [mov("2026-11-03", "Transferencia recibida", 29000, "ARS", "s9")] }));
console.log("S fuente tras el resumen:", (await db.query("select saldo, fuente from saldos where cuenta_id = 1 and fecha = '2026-11-05'")).rows[0]);

// T) Tipos de cambio
console.log("T cotizaciones:", (await db.query(`select registrar_tipos_cambio('{"cotizaciones":[{"fecha":"2026-10-23","tipo":"mep","compra":1500,"venta":1510},{"fecha":"2026-10-23","tipo":"blue","venta":1530},{"fecha":"2026-10-23","tipo":"raro","venta":1}]}'::jsonb) as n`)).rows[0].n,
  (await db.query("select tipo, venta from tipos_cambio order by tipo")).rows);
