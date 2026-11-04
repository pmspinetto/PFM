-- =====================================================================
-- Integridad: que cada movimiento impacte una sola vez y en todos los lugares que corresponde.
-- Surge de una revisión completa de la app y de la base (noviembre 2026).
--
-- 1. Fechas: la base usa la hora de Argentina (current_date era UTC: después de las 21 h ya era mañana).
-- 2. Vínculos:
--    - borrar la entrada de una transferencia interna deja la salida "en tránsito" (antes borraba el par);
--    - borrar un movimiento borra el registro del vencimiento que pagaba, que vuelve a proyectarse.
-- 3. Saldos informados y arqueos: lo anotado después, el mismo día, también cuenta (saldos.creado_en).
-- 4. v_flujo_proyectado: cada ocurrencia se calcula desde la primera fecha (un día 31 ya no queda en 28).
-- 5. guardar_importacion:
--    - el resumen que reemplaza un movimiento de mail o anotado a mano primero inserta y después traslada
--      todo lo del anterior (transferencia interna, vencimiento registrado, aviso, bien, compra, para quién,
--      extraordinario y el rubro elegido a mano) antes de borrarlo;
--    - solo absorbe avisos hasta el cierre y no cuando la línea del resumen ya estaba importada;
--    - no crea otra contraparte de efectivo si el retiro o el depósito ya estaba emparejado (anotado a mano);
--    - registra los vencimientos de fijos y de tarjeta que el resumen paga o cobra;
--    - "Recordar" con un patrón que ya existía actualiza esa regla.
-- 6. registrar_aviso:
--    - si el movimiento ya vino en un resumen, el aviso lo confirma (no lo duplica);
--    - la entrada de una transferencia interna solo se vincula con un anotado, un mail o una transferencia
--      interna (no con un ingreso real) y las dos puntas quedan conciliadas.
-- 7. alertas_calcular:
--    - gasto grande: solo de los últimos 7 días y no repite lo ya avisado por mail;
--    - pagos recurrentes: respeta la cuenta, la fecha de fin, los omitidos y no cuenta los sugeridos.
-- 8. borrar_movimiento(id): borra un movimiento anotado a mano o llegado por mail con todo lo que cuelga de él.
-- 9. Datos: corrige un pago de tarjeta clasificado como gasto, quita un registro de vencimiento sin movimiento
--    con una fecha que no corresponde y marca conciliadas las transferencias de mail ya emparejadas.
-- =====================================================================

-- 1. Hora de Argentina
do $$
begin
  execute format('alter database %I set timezone to %L', current_database(), 'America/Argentina/Buenos_Aires');
exception when others then
  raise notice 'No se pudo fijar la zona horaria: %', sqlerrm;
end $$;
set timezone to 'America/Argentina/Buenos_Aires';

-- 2. Vínculos
alter table transferencias_internas drop constraint if exists transferencias_internas_mov_entrada_id_fkey;
alter table transferencias_internas add constraint transferencias_internas_mov_entrada_id_fkey
  foreign key (mov_entrada_id) references movimientos(id) on delete set null;
alter table compromisos_registrados drop constraint if exists compromisos_registrados_movimiento_id_fkey;
alter table compromisos_registrados add constraint compromisos_registrados_movimiento_id_fkey
  foreign key (movimiento_id) references movimientos(id) on delete cascade;

-- 3. Momento de cada saldo
alter table saldos add column if not exists creado_en timestamptz not null default now();
create or replace function saldos_momento() returns trigger language plpgsql as $f$
begin
  new.creado_en := now();
  return new;
end $f$;
drop trigger if exists saldos_momento on saldos;
create trigger saldos_momento before update of saldo, fuente on saldos for each row execute function saldos_momento();

-- 4. Flujo proyectado
create or replace view v_flujo_proyectado with (security_invoker = on) as
select c.id as compromiso_id, c.descripcion, c.tipo, c.indexacion,
       gs.fecha,
       round(c.monto * case when c.indexacion = 'ipc' and c.ultimo_ajuste is not null
                            then factor_ipc(c.ultimo_ajuste, gs.fecha, coalesce(c.ajuste_cada, 3)) else 1 end, 2)::numeric(18,2) as monto,
       c.moneda,
       false as aguinaldo
from compromisos c
cross join lateral (
  -- Cada ocurrencia se calcula desde la primera fecha (no sumando un mes a la anterior), así un día 31
  -- vuelve a ser 31 después de febrero
  select case when c.frecuencia = 'unica' then c.fecha_proxima
              else (c.fecha_proxima + k * case c.frecuencia when 'mensual' then interval '1 month'
                                                            when 'trimestral' then interval '3 months'
                                                            when 'semestral' then interval '6 months'
                                                            else interval '1 year' end)::date end as fecha
  from generate_series(0, case when c.frecuencia = 'unica' then 0 else 600 end) k
) gs
where c.activo
  and gs.fecha <= case when c.frecuencia = 'unica' then c.fecha_proxima
                       else least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months')::date end
  and not exists (select 1 from compromisos_registrados x
                  where x.compromiso_id = c.id and x.fecha = gs.fecha and not x.aguinaldo)
union all
select c.id, 'Aguinaldo · ' || c.descripcion, c.tipo, 'estimado',
       a.fecha,
       round(c.monto * c.aguinaldo / 100
             * case when c.indexacion = 'ipc' and c.ultimo_ajuste is not null
                    then factor_ipc(c.ultimo_ajuste, a.fecha, coalesce(c.ajuste_cada, 3)) else 1 end, 2)::numeric(18,2),
       c.moneda,
       true
from compromisos c
cross join lateral (
  select make_date(y, m, d) as fecha
  from generate_series(extract(year from current_date)::int, extract(year from current_date)::int + 1) y
  cross join (values (6, 30), (12, 18)) md(m, d)
) a
where c.activo and c.aguinaldo is not null and c.frecuencia = 'mensual'
  and a.fecha >= greatest(c.fecha_proxima, current_date)
  and not exists (select 1 from compromisos_registrados x
                  where x.compromiso_id = c.id and x.fecha = a.fecha and x.aguinaldo)
  and a.fecha <= least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months');

-- 3. Saldo vivo
create or replace view v_saldo_vivo with (security_invoker = on) as
with ultimo as (
  select distinct on (cuenta_id, moneda) cuenta_id, moneda, fecha, saldo, fuente, creado_en
  from saldos order by cuenta_id, moneda, fecha desc
)
select c.alias, u.moneda, u.fecha as confirmado_al, u.saldo as saldo_confirmado,
       coalesce(sum(m.monto), 0)    as movimientos_posteriores,
       count(m.id)                  as cant_movimientos,
       u.saldo + coalesce(sum(m.monto), 0) as saldo_estimado,
       u.cuenta_id, u.fuente
from ultimo u
join cuentas c on c.id = u.cuenta_id
left join movimientos m on m.cuenta_id = u.cuenta_id and m.moneda = u.moneda
  and (m.fecha > u.fecha
       -- un saldo informado o un arqueo es una foto de ese momento: lo anotado después, el mismo día, también cuenta
       or (m.fecha = u.fecha and u.fuente <> 'resumen' and m.creado_en > u.creado_en))
group by c.alias, u.moneda, u.fecha, u.saldo, u.cuenta_id, u.fuente;

-- 5. Importador
create or replace function guardar_importacion(p jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_cuenta   bigint := (p->>'cuenta_id')::bigint;
  v_doc      bigint;
  v_ins      int;
  v_pares    int := 0;
  v_dif      numeric;
  v_eid      bigint;
  v_internos bigint[];
  r          record;
  v_tar      jsonb := p->'documento'->'tarjeta';
  v_cierre   date  := (p->'documento'->>'periodo_hasta')::date;
  v_alias    text;
  v_rubro    bigint;
  v_mail     record;
  v_comb     record;
  v_efectivo bigint;
  v_caja     bigint;
  v_nuevo    bigint;
  v_alias_c  text;
  v_persona_c bigint;
  v_meses    jsonb;
  v_sin      int := 0;
  v_n        int;
  v_absorbidos jsonb := '[]';
  v_pago     bigint;
begin
  if not es_autorizado() then
    raise exception 'No autorizado';
  end if;

  select array_agg(id) into v_internos
  from rubros
  where nombre in ('Transferencia interna','Pago de tarjeta','Movimiento de efectivo')
    and padre_id is not null;

  -- Documento
  insert into documentos (cuenta_id, tipo, periodo_desde, periodo_hasta, hash,
                          vencimiento, proximo_cierre, proximo_vencimiento, pago_minimo)
  values (v_cuenta,
          p->'documento'->>'tipo',
          (p->'documento'->>'periodo_desde')::date,
          v_cierre,
          p->'documento'->>'hash',
          nullif(v_tar->>'vencimiento','')::date,
          nullif(v_tar->>'proximo_cierre','')::date,
          nullif(v_tar->>'proximo_vencimiento','')::date,
          nullif(v_tar->>'pago_minimo','')::numeric)
  on conflict (hash) do nothing
  returning id into v_doc;

  if v_doc is null then
    raise exception 'Este resumen ya fue importado para esta cuenta';
  end if;

  -- Saldos inicial y final
  insert into saldos (cuenta_id, fecha, moneda, saldo)
  select v_cuenta, (c->>'fecha_inicial')::date, c->>'moneda', (c->>'saldo_inicial')::numeric
  from jsonb_array_elements(p->'conciliar') c
  union all
  select v_cuenta, (c->>'fecha_final')::date, c->>'moneda', (c->>'saldo_final')::numeric
  from jsonb_array_elements(p->'conciliar') c
  on conflict (cuenta_id, fecha, moneda) do update
    set saldo = excluded.saldo, fuente = 'resumen'
    where saldos.fuente <> 'resumen';   -- el resumen reemplaza un saldo informado o de arqueo del mismo día

  -- Avisos por mail y movimientos anotados a mano que este resumen confirma: se reemplazan por el movimiento del resumen
  -- (misma cuenta, moneda e importe; fecha de la operación a 5 días o menos). En compras
  -- en cuotas se compara con la fecha original y se tolera $1 por el redondeo de la cuota.
  for r in
    select m->>'id_externo' as id_externo, m->>'moneda' as moneda, (m->>'monto')::numeric as monto,
           coalesce(to_date(substring(m->>'descripcion_original' from 'compra original (\d{2}/\d{2}/\d{2})'), 'DD/MM/YY'),
                    (m->>'fecha')::date) as fecha_op
    from jsonb_array_elements(p->'movimientos') m
    where not exists (select 1 from movimientos d where d.cuenta_id = v_cuenta and d.id_externo = m->>'id_externo')
  loop
    select x.id, a.id as aviso_id into v_mail
    from movimientos x
    left join avisos a on a.movimiento_id = x.id
    where x.cuenta_id = v_cuenta and (x.origen = 'mail' or (x.origen = 'manual' and x.id_externo like 'manual:%')) and x.moneda = r.moneda
      and abs(x.monto - r.monto) < case when coalesce(x.cuotas_total, 1) > 1 then 1 else 0.01 end
      and abs(x.fecha - r.fecha_op) <= 5
      and x.fecha <= v_cierre
      and not exists (select 1 from jsonb_array_elements(v_absorbidos) e where (e->>'mov')::bigint = x.id)
    order by abs(x.fecha - r.fecha_op), x.id
    limit 1;
    if v_mail.id is not null then
      v_absorbidos := v_absorbidos || jsonb_build_object('mov', v_mail.id, 'aviso', v_mail.aviso_id, 'id_externo', r.id_externo);
    end if;
  end loop;


  -- Movimientos
  with nuevos as (
    insert into movimientos (
      cuenta_id, plastico_id, fecha, descripcion_original, monto, moneda, tipo_cambio,
      rubro_id, persona_id, beneficiario_id, activo_id, es_extraordinario,
      cuota_nro, cuotas_total, comprobante, id_externo, origen, confianza,
      estado_conciliacion, documento_id, notas)
    select v_cuenta,
           nullif(m->>'plastico_id','')::bigint,
           (m->>'fecha')::date,
           m->>'descripcion_original',
           (m->>'monto')::numeric,
           m->>'moneda',
           nullif(m->>'tipo_cambio','')::numeric,
           nullif(m->>'rubro_id','')::bigint,
           nullif(m->>'persona_id','')::bigint,
           nullif(m->>'beneficiario_id','')::bigint,
           nullif(m->>'activo_id','')::bigint,
           coalesce((m->>'es_extraordinario')::boolean, false),
           nullif(m->>'cuota_nro','')::int,
           nullif(m->>'cuotas_total','')::int,
           m->>'comprobante',
           m->>'id_externo',
           'resumen',
           coalesce(m->>'confianza','confirmado'),
           'conciliado',
           v_doc,
           m->>'notas'
    from jsonb_array_elements(p->'movimientos') m
    on conflict (cuenta_id, id_externo) do nothing
    returning id
  )
  select count(*) into v_ins from nuevos;

  create temp table if not exists _abs (viejo bigint, nuevo bigint) on commit drop;
  delete from _abs;
  insert into _abs
  select (e->>'mov')::bigint, mv.id
  from jsonb_array_elements(v_absorbidos) e
  join movimientos mv on mv.cuenta_id = v_cuenta and mv.id_externo = e->>'id_externo' and mv.documento_id = v_doc;
  update movimientos n
  set beneficiario_id = coalesce(n.beneficiario_id, o.beneficiario_id), activo_id = coalesce(n.activo_id, o.activo_id),
      compra_id = coalesce(n.compra_id, o.compra_id), persona_id = coalesce(n.persona_id, o.persona_id),
      es_extraordinario = n.es_extraordinario or o.es_extraordinario,
      rubro_id = case when o.origen = 'manual' and o.rubro_id is not null then o.rubro_id else coalesce(n.rubro_id, o.rubro_id) end
  from _abs x join movimientos o on o.id = x.viejo where n.id = x.nuevo;
  update transferencias_internas t set mov_salida_id = x.nuevo from _abs x where t.mov_salida_id = x.viejo;
  update transferencias_internas t set mov_entrada_id = x.nuevo from _abs x where t.mov_entrada_id = x.viejo;
  update compromisos_registrados k set movimiento_id = x.nuevo from _abs x where k.movimiento_id = x.viejo;
  update avisos a set movimiento_id = x.nuevo, estado = case when a.estado = 'registrado' then 'confirmado' else a.estado end
  from _abs x where a.movimiento_id = x.viejo;
  delete from movimientos where id in (select (e->>'mov')::bigint from jsonb_array_elements(v_absorbidos) e);

  -- Cada aviso absorbido queda apuntando al movimiento del resumen que lo confirmó
  update avisos a set movimiento_id = mv.id, estado = 'confirmado'
  from jsonb_array_elements(v_absorbidos) e
  join movimientos mv on mv.cuenta_id = v_cuenta and mv.id_externo = e->>'id_externo'
  where a.id = (e->>'aviso')::bigint;

  -- Desglose de movimientos (ej.: cuota hipotecaria en capital, intereses y seguros)
  insert into movimiento_partes (movimiento_id, rubro_id, monto, concepto)
  select mv.id, rb.id, (pt->>'monto')::numeric, pt->>'concepto'
  from jsonb_array_elements(p->'movimientos') m
  cross join lateral jsonb_array_elements(coalesce(m->'partes', '[]'::jsonb)) pt
  join movimientos mv on mv.cuenta_id = v_cuenta and mv.id_externo = m->>'id_externo' and mv.documento_id = v_doc
  join rubros rb on rb.nombre = pt->>'rubro' and rb.padre_id is not null;

  -- Saldo actualizado de préstamos
  update prestamos pr
  set saldo_capital = (m->'prestamo'->>'saldo')::numeric,
      cuota_actual  = (m->'prestamo'->>'cuota_actual')::int,
      saldo_fecha   = (m->'prestamo'->>'fecha')::date
  from jsonb_array_elements(p->'movimientos') m
  where jsonb_typeof(m->'prestamo') = 'object'
    and pr.numero = m->'prestamo'->>'numero'
    and (m->'prestamo'->>'fecha')::date >= pr.saldo_fecha;

  -- Conciliación obligatoria
  for r in
    select c->>'moneda' as moneda,
           (c->>'fecha_inicial')::date as fi, (c->>'fecha_final')::date as ff,
           (c->>'saldo_inicial')::numeric as si, (c->>'saldo_final')::numeric as sf
    from jsonb_array_elements(p->'conciliar') c
  loop
    select r.si + coalesce(sum(monto), 0) - r.sf into v_dif
    from movimientos
    where cuenta_id = v_cuenta and moneda = r.moneda and origen <> 'mail'
      and not (origen = 'manual' and coalesce(id_externo, '') like 'manual:%')
      and fecha > r.fi and fecha <= r.ff;

    if abs(v_dif) >= 0.01 then
      raise exception 'La cuenta no concilia en %: diferencia de % (¿hay movimientos cargados antes por otra vía?)',
        r.moneda, v_dif;
    end if;
  end loop;

  -- Avisos por mail y anotados a mano del período que el resumen no confirmó: quedan para revisar
  -- (pueden venir en el próximo resumen; si aparecen, se absorben igual)
  for r in
    select (c->>'moneda') as moneda, (c->>'fecha_inicial')::date as fi, (c->>'fecha_final')::date as ff
    from jsonb_array_elements(p->'conciliar') c
  loop
    update movimientos
    set confianza = 'sugerido',
        notas = concat_ws(' · ', notas, format('No apareció en el resumen al %s (puede venir en el próximo)', to_char(r.ff, 'DD/MM')))
    where cuenta_id = v_cuenta and (origen = 'mail' or (origen = 'manual' and id_externo like 'manual:%')) and moneda = r.moneda
      and fecha > r.fi and fecha <= r.ff and confianza <> 'sugerido';
    get diagnostics v_n = row_count;
    v_sin := v_sin + v_n;
  end loop;

  -- Recordar el número y el CBU de la cuenta para reconocerla sola la próxima vez
  update cuentas
  set numero  = coalesce(numero,  nullif(p->'identificador'->>'numero','')),
      cbu_cvu = coalesce(cbu_cvu, nullif(p->'identificador'->>'cbu',''))
  where id = v_cuenta;

  -- Vencimientos de tarjeta como compromisos (solo si es el resumen más reciente de la cuenta):
  -- el del resumen actual con su saldo, y el del próximo con las cuotas ya conocidas
  if v_tar ? 'vencimiento' and not exists (
       select 1 from documentos d
       where d.cuenta_id = v_cuenta and d.tipo = 'resumen_tarjeta' and d.periodo_hasta > v_cierre) then
    select alias into v_alias from cuentas where id = v_cuenta;
    select id into v_rubro from rubros where nombre = 'Pago de tarjeta' and padre_id is not null;

    update compromisos set activo = false
    where cuenta_id = v_cuenta and tipo = 'vencimiento_tarjeta' and activo;

    insert into compromisos (descripcion, tipo, cuenta_id, rubro_id, monto, moneda, indexacion,
                             frecuencia, fecha_proxima, documento_id)
    select format('Resumen %s (cierre %s)', v_alias, to_char(v_cierre, 'DD/MM')),
           'vencimiento_tarjeta', v_cuenta, v_rubro, (c->>'saldo_final')::numeric, c->>'moneda',
           'ninguna', 'unica', (v_tar->>'vencimiento')::date, v_doc
    from jsonb_array_elements(p->'conciliar') c
    where (c->>'saldo_final')::numeric < 0 and nullif(v_tar->>'vencimiento','') is not null;

    -- Próximos resúmenes: las cuotas que quedan de cada compra en cuotas, mes por mes
    -- ("cuota 2 de 12" deja 10 meses más). El primero se vence en el próximo vencimiento.
    select jsonb_agg(jsonb_build_object('k', k, 'moneda', moneda, 'monto', monto) order by k, moneda) into v_meses
    from (
      select g.k, c.moneda, sum(c.monto) as monto
      from (
        select m->>'moneda' as moneda, (m->>'monto')::numeric as monto,
               (m->>'cuotas_total')::int - (m->>'cuota_nro')::int as restantes
        from jsonb_array_elements(p->'movimientos') m
        where nullif(m->>'cuotas_total', '') is not null and nullif(m->>'cuota_nro', '') is not null
          and (m->>'monto')::numeric < 0
      ) c
      cross join lateral generate_series(1, c.restantes) as g(k)
      where c.restantes > 0
      group by g.k, c.moneda
    ) x;

    insert into compromisos (descripcion, tipo, cuenta_id, rubro_id, monto, moneda, indexacion,
                             frecuencia, fecha_proxima, documento_id)
    select case when x.k = 1
                then format('Próximo resumen %s (cuotas ya conocidas; los consumos nuevos se suman al cerrar)', v_alias)
                else format('Cuotas %s · resumen de %s', v_alias,
                            to_char((v_tar->>'proximo_vencimiento')::date + (x.k - 1) * interval '1 month', 'MM/YYYY')) end,
           'vencimiento_tarjeta', v_cuenta, v_rubro, x.monto, x.moneda, 'estimado', 'unica',
           ((v_tar->>'proximo_vencimiento')::date + (x.k - 1) * interval '1 month')::date, v_doc
    from jsonb_to_recordset(coalesce(v_meses, '[]'::jsonb)) as x(k int, moneda text, monto numeric)
    where nullif(v_tar->>'proximo_vencimiento', '') is not null;

    -- Si no hay cuotas en pesos, igual se agenda la fecha del próximo vencimiento
    insert into compromisos (descripcion, tipo, cuenta_id, rubro_id, monto, moneda, indexacion,
                             frecuencia, fecha_proxima, documento_id)
    select format('Próximo resumen %s (los consumos nuevos se suman al cerrar)', v_alias),
           'vencimiento_tarjeta', v_cuenta, v_rubro,
           -coalesce(nullif(v_tar->>'cuotas_proximo_resumen','')::numeric, 0), 'ARS',
           'estimado', 'unica', (v_tar->>'proximo_vencimiento')::date, v_doc
    where nullif(v_tar->>'proximo_vencimiento','') is not null
      and not exists (select 1 from jsonb_array_elements(coalesce(v_meses, '[]'::jsonb)) e
                      where (e->>'k')::int = 1 and e->>'moneda' = 'ARS');
  end if;

  -- Registrar como pendientes las salidas internas nuevas de este resumen
  insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo)
  select m.id, null,
         case rb.nombre when 'Pago de tarjeta' then 'pago_tarjeta'
                        when 'Movimiento de efectivo' then 'efectivo'
                        else 'transferencia' end
  from movimientos m
  join rubros rb on rb.id = m.rubro_id
  where m.documento_id = v_doc and m.monto < 0 and m.rubro_id = any(v_internos)
    and not exists (select 1 from transferencias_internas x where x.mov_salida_id = m.id);

  update movimientos m set estado_conciliacion = case when exists (
      select 1 from transferencias_internas t where (t.mov_salida_id = m.id and t.mov_entrada_id is not null) or t.mov_entrada_id = m.id)
    then 'conciliado' else 'pendiente' end
  where documento_id = v_doc and rubro_id = any(v_internos);

  -- Retiros y depósitos de efectivo: la contraparte va a la caja de efectivo de la misma moneda
  -- (de la misma persona si tiene una), ya emparejada
  select id into v_efectivo from rubros where nombre = 'Movimiento de efectivo' and padre_id is not null;
  select alias, persona_id into v_alias_c, v_persona_c from cuentas where id = v_cuenta;
  for r in
    select m.id, m.fecha, m.monto, m.moneda
    from movimientos m
    where m.documento_id = v_doc and m.rubro_id = v_efectivo
  loop
    select c.id into v_caja from cuentas c
    where c.tipo = 'caja_efectivo' and c.activa and c.moneda = r.moneda and c.id <> v_cuenta
    order by (c.persona_id = v_persona_c) desc, c.id
    limit 1;
    continue when v_caja is null;
    continue when exists (select 1 from transferencias_internas t
                          where (t.mov_salida_id = r.id and t.mov_entrada_id is not null) or t.mov_entrada_id = r.id);

    v_nuevo := null;
    insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, rubro_id, persona_id,
                             id_externo, origen, confianza, estado_conciliacion, notas)
    values (v_caja, r.fecha,
            case when r.monto < 0 then 'Retiro de efectivo' else 'Depósito de efectivo' end || ' · ' || v_alias_c,
            -r.monto, r.moneda, v_efectivo, v_persona_c, 'efectivo:' || r.id, 'manual', 'confirmado', 'conciliado',
            'Generado al importar el resumen')
    on conflict (cuenta_id, id_externo) do nothing
    returning id into v_nuevo;
    continue when v_nuevo is null;

    if r.monto < 0 then      -- retiro: la salida del banco ya está registrada; se completa con la caja
      update transferencias_internas set mov_entrada_id = v_nuevo
      where mov_salida_id = r.id and mov_entrada_id is null;
    else                     -- depósito: la salida es de la caja
      insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo) values (v_nuevo, r.id, 'efectivo');
    end if;
    update movimientos set estado_conciliacion = 'conciliado' where id in (r.id, v_nuevo);
  end loop;

  -- Emparejar todas las salidas internas sin contraparte (de este o de meses anteriores)
  for r in
    select t.id as tid, s.id as sid, s.cuenta_id, s.monto, s.moneda, s.fecha
    from transferencias_internas t
    join movimientos s on s.id = t.mov_salida_id
    where t.mov_entrada_id is null
    order by s.fecha, s.id
  loop
    select e.id into v_eid
    from movimientos e
    where e.rubro_id = any(v_internos)
      and e.monto = -r.monto and e.moneda = r.moneda
      and e.cuenta_id <> r.cuenta_id
      and abs(e.fecha - r.fecha) <= 5
      and not exists (select 1 from transferencias_internas x where x.mov_entrada_id = e.id)
    order by abs(e.fecha - r.fecha), e.id
    limit 1;

    if v_eid is not null then
      update transferencias_internas set mov_entrada_id = v_eid where id = r.tid;
      update movimientos set estado_conciliacion = 'conciliado' where id in (r.sid, v_eid);
      v_pares := v_pares + 1;
    end if;
  end loop;

  -- Pagos de tarjeta en pesos que cancelan saldo en dólares: un débito en pesos se empareja
  -- con la entrada en dólares de la tarjeta (convertida al tipo de cambio del resumen) y,
  -- si el mismo débito también pagó el saldo en pesos, con esa entrada en pesos.
  -- Sirve también para completar pagos que ya tenían emparejada solo la parte en pesos.
  for r in
    select x.sid, x.fecha, x.cuenta_id, x.cuenta_tarjeta, x.total - x.cubierto as falta, x.cubierto
    from (
      select s.id as sid, s.fecha, s.cuenta_id, -s.monto as total, min(e.cuenta_id) as cuenta_tarjeta,
             coalesce(sum(case when e.moneda = 'ARS' then e.monto else round(e.monto * e.tipo_cambio, 2) end), 0) as cubierto
      from transferencias_internas t
      join movimientos s on s.id = t.mov_salida_id
      left join movimientos e on e.id = t.mov_entrada_id
      where t.tipo = 'pago_tarjeta' and s.moneda = 'ARS'
      group by s.id
    ) x
    where x.total - x.cubierto > 1
    order by x.fecha, x.sid
  loop
    select a.id as ars_id, u.id as usd_id into v_comb
    from movimientos u
    cross join lateral (
      select a.id, a.monto from movimientos a
      where r.cubierto = 0 and a.cuenta_id = u.cuenta_id and a.moneda = 'ARS' and a.monto > 0
        and a.rubro_id = any(v_internos) and abs(a.fecha - r.fecha) <= 5
        and not exists (select 1 from transferencias_internas x where x.mov_entrada_id = a.id)
      union all
      select null::bigint, 0::numeric
    ) a
    where u.moneda = 'USD' and u.monto > 0 and u.tipo_cambio > 0 and u.rubro_id = any(v_internos)
      and u.cuenta_id <> r.cuenta_id
      and (r.cuenta_tarjeta is null or u.cuenta_id = r.cuenta_tarjeta)
      and abs(u.fecha - r.fecha) <= 5
      and not exists (select 1 from transferencias_internas x where x.mov_entrada_id = u.id)
      and abs(a.monto + round(u.monto * u.tipo_cambio, 2) - r.falta) <= greatest(1, r.falta * 0.0005)
    order by abs(a.monto + round(u.monto * u.tipo_cambio, 2) - r.falta), a.id nulls last, u.id
    limit 1;

    if v_comb.usd_id is not null then
      -- La fila pendiente (sin contraparte) toma la primera entrada; las demás van en filas nuevas
      update transferencias_internas set mov_entrada_id = coalesce(v_comb.ars_id, v_comb.usd_id)
      where mov_salida_id = r.sid and mov_entrada_id is null;
      insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo)
      select r.sid, e.id, 'pago_tarjeta'
      from unnest(array[v_comb.ars_id, v_comb.usd_id]) as e(id)
      where e.id is not null
        and not exists (select 1 from transferencias_internas x where x.mov_entrada_id = e.id);
      update movimientos set estado_conciliacion = 'conciliado'
      where id in (r.sid, v_comb.ars_id, v_comb.usd_id);
      v_pares := v_pares + 1;
    end if;
  end loop;

  -- Vencimientos de fijos que este resumen cobra o paga (mismo criterio que los avisos: moneda y signo,
  -- importe ±1 %, fecha ±3 días, en la cuenta del compromiso si tiene una): quedan registrados y dejan
  -- de proyectarse. Antes solo se registraban con "Ya entró"/"Ya lo pagué" o por aviso de mail.
  for r in
    select m.id, m.cuenta_id, m.fecha, m.monto, m.moneda from movimientos m
    where m.documento_id = v_doc and coalesce(m.rubro_id <> all(v_internos), true)
      and not exists (select 1 from compromisos_registrados x where x.movimiento_id = m.id)
    order by m.fecha, m.id
  loop
    insert into compromisos_registrados (compromiso_id, fecha, aguinaldo, movimiento_id)
    select f.compromiso_id, f.fecha, f.aguinaldo, r.id
    from v_flujo_proyectado f
    join compromisos k on k.id = f.compromiso_id
    where k.tipo <> 'vencimiento_tarjeta' and f.moneda = r.moneda and sign(f.monto) = sign(r.monto)
      and abs(abs(f.monto) - abs(r.monto)) <= abs(f.monto) * 0.01 and abs(f.fecha - r.fecha) <= 3
      and (k.cuenta_id is null or k.cuenta_id = r.cuenta_id)
    order by abs(f.fecha - r.fecha), abs(abs(f.monto) - abs(r.monto)), f.compromiso_id
    limit 1
    on conflict do nothing;
  end loop;

  -- Pagos de tarjeta de este resumen: registran el vencimiento de tarjeta que cancelan (mismo importe,
  -- pagado después del cierre y a más tardar 5 días después del vencimiento)
  select id into v_pago from rubros where nombre = 'Pago de tarjeta' and padre_id is not null;
  insert into compromisos_registrados (compromiso_id, fecha, aguinaldo, movimiento_id)
  select distinct on (k.id) k.id, k.fecha_proxima, false, m.id
  from movimientos m
  join compromisos k on k.tipo = 'vencimiento_tarjeta' and k.activo and k.moneda = m.moneda
  join documentos d on d.id = k.documento_id
  where m.documento_id = v_doc and m.monto < 0 and m.rubro_id = v_pago
    and m.fecha > d.periodo_hasta and m.fecha <= k.fecha_proxima + 5 and abs(m.monto - k.monto) <= 1
    and not exists (select 1 from compromisos_registrados x where x.movimiento_id = m.id)
  order by k.id, abs(k.fecha_proxima - m.fecha)
  on conflict do nothing;

  -- Cuántas veces se aplicó cada regla (para la pantalla de reglas)
  update reglas g set veces_aplicada = g.veces_aplicada + x.n
  from (select (m->>'regla_id')::bigint as id, count(*) as n
        from jsonb_array_elements(p->'movimientos') m
        where nullif(m->>'regla_id', '') is not null
        group by 1) x
  where g.id = x.id;

  -- Reglas nuevas ("Recordar"): si ya había una regla con el mismo patrón, se actualiza con lo elegido ahora
  update reglas g
  set rubro_id = coalesce(nullif(x->>'rubro_id','')::bigint, g.rubro_id),
      activo_id = nullif(x->>'activo_id','')::bigint,
      beneficiario_id = nullif(x->>'beneficiario_id','')::bigint,
      es_extraordinario = nullif(x->>'es_extraordinario','')::boolean,
      modo = coalesce(x->>'modo', g.modo), confianza = 'confirmado'
  from jsonb_array_elements(coalesce(p->'reglas_nuevas','[]'::jsonb)) x
  where g.patron = x->>'patron';

  insert into reglas (prioridad, patron, modo, rubro_id, activo_id, beneficiario_id,
                      es_extraordinario, confianza)
  select 15, x->>'patron', coalesce(x->>'modo','auto'),
         nullif(x->>'rubro_id','')::bigint,
         nullif(x->>'activo_id','')::bigint,
         nullif(x->>'beneficiario_id','')::bigint,
         nullif(x->>'es_extraordinario','')::boolean,
         'confirmado'
  from jsonb_array_elements(coalesce(p->'reglas_nuevas','[]'::jsonb)) x
  where not exists (select 1 from reglas g where g.patron = x->>'patron');

  return jsonb_build_object(
    'insertados', v_ins,
    'duplicados', jsonb_array_length(p->'movimientos') - v_ins,
    'emparejadas', v_pares,
    'absorbidos', jsonb_array_length(v_absorbidos),
    'sin_confirmar', v_sin);
end;
$$;

-- 6. Avisos
create or replace function registrar_aviso(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a          jsonb := p->'aviso';
  v_estado   text  := coalesce(nullif(p->>'estado', ''), 'registrado');
  v_aviso    bigint;
  v_cuenta   bigint;
  v_plastico bigint;
  v_persona  bigint;
  v_mov      bigint;
  v_cuotas   int;
  v_monto    numeric;
  v_desc     text;
  v_n        int;
  v_comp     text;
  v_id_ext   text;
  v_previo   record;
  v_destino  bigint;
  v_interna  bigint;
  v_fecha    date;
  v_k_id     bigint;
  v_k_fecha  date;
  v_k_agui   boolean;
  v_k_rubro  bigint;
  v_k_activo bigint;
  v_manual   bigint;
  v_entrada  bigint;
  v_res      bigint;
  rg         record;
begin
  if not (es_autorizado() or exists (select 1 from capturadores where user_id = auth.uid())) then
    raise exception 'No autorizado';
  end if;
  if coalesce(p->>'message_id', '') = '' then
    raise exception 'Aviso incompleto';
  end if;

  -- Mails que no se pudieron leer: se guardan igual para que quede rastro
  if v_estado in ('no_reconocido', 'error', 'sospechoso') then
    insert into avisos (message_id, remitente, asunto, recibido, banco, tipo, datos, estado)
    values (left(p->>'message_id', 300), left(p->>'remitente', 300), left(p->>'asunto', 300),
            nullif(p->>'recibido', '')::timestamptz, left(p->>'banco', 50), null,
            coalesce(p->'datos', '{}'::jsonb), v_estado)
    on conflict (message_id) do update
      set datos = excluded.datos, estado = excluded.estado
      where avisos.estado in ('no_reconocido', 'error', 'sospechoso')
    returning id into v_aviso;
    return jsonb_build_object('estado', case when v_aviso is null then 'duplicado' else v_estado end, 'aviso_id', v_aviso);
  end if;

  if a is null
     or a->>'tipo' not in ('consumo_tarjeta','transferencia_enviada','transferencia_recibida')
     or a->>'moneda' not in ('ARS','USD')
     or coalesce((a->>'monto')::numeric, 0) = 0 then
    raise exception 'Aviso incompleto';
  end if;

  insert into avisos (message_id, remitente, asunto, recibido, banco, tipo, datos)
  values (left(p->>'message_id', 300), left(p->>'remitente', 300), left(p->>'asunto', 300),
          nullif(p->>'recibido', '')::timestamptz, left(a->>'banco', 50), a->>'tipo', a)
  on conflict (message_id) do update
    set banco = excluded.banco, tipo = excluded.tipo, datos = excluded.datos, estado = 'pendiente'
    where avisos.estado in ('no_reconocido', 'error', 'sospechoso')
  returning id into v_aviso;
  if v_aviso is null then
    return jsonb_build_object('estado', 'duplicado');
  end if;

  -- Otra copia del mismo aviso (mismo comprobante y banco): se guarda como duplicado
  v_comp := nullif(regexp_replace(coalesce(a->>'comprobante', ''), '\s', '', 'g'), '');
  if v_comp is not null then
    select av.id, av.movimiento_id, av.cuenta_id into v_previo
    from avisos av
    where av.id <> v_aviso and av.banco = a->>'banco' and av.datos->>'comprobante' is not null
      and regexp_replace(av.datos->>'comprobante', '\s', '', 'g') = v_comp
      and av.estado in ('registrado', 'confirmado', 'sin_cuenta')
    order by av.id
    limit 1;
    if v_previo.id is not null then
      update avisos set estado = 'duplicado', movimiento_id = v_previo.movimiento_id, cuenta_id = v_previo.cuenta_id
      where id = v_aviso;
      return jsonb_build_object('estado', 'duplicado', 'aviso_id', v_aviso, 'de', v_previo.id);
    end if;
  end if;

  -- Cuenta: por plástico (tarjetas) o por número de cuenta, siempre dentro del mismo banco
  if coalesce(a->>'ultimos4', '') <> '' then
    select count(*), min(pl.id), min(pl.cuenta_id), min(pl.persona_id)
      into v_n, v_plastico, v_cuenta, v_persona
    from plasticos pl
    join cuentas c on c.id = pl.cuenta_id and c.activa
    join instituciones i on i.id = c.institucion_id and i.nombre = a->>'banco'
    where pl.ultimos4 = a->>'ultimos4';
  elsif coalesce(a->>'cuenta', '') <> '' then
    select count(*), min(c.id), min(c.persona_id)
      into v_n, v_cuenta, v_persona
    from cuentas c
    join instituciones i on i.id = c.institucion_id and i.nombre = a->>'banco'
    where c.activa and c.moneda in (a->>'moneda', 'BIMONEDA')
      and regexp_replace(coalesce(c.numero, '') || ' ' || coalesce(c.cbu_cvu, ''), '\D', '', 'g')
          like '%' || regexp_replace(a->>'cuenta', '\D', '', 'g') || '%';
  end if;
  if coalesce(v_n, 0) <> 1 then
    update avisos set estado = 'sin_cuenta' where id = v_aviso;
    return jsonb_build_object('estado', 'sin_cuenta', 'aviso_id', v_aviso);
  end if;

  -- En cuotas, el resumen va a mostrar la primera cuota: se registra esa
  v_cuotas := greatest(coalesce((a->>'cuotas')::int, 1), 1);
  v_monto  := round((a->>'monto')::numeric / v_cuotas, 2);
  v_desc   := left(coalesce(nullif(a->>'descripcion', ''), 'Aviso ' || (a->>'banco')), 300);
  v_fecha  := coalesce(nullif(a->>'fecha', '')::date, (p->>'recibido')::date, current_date);
  v_id_ext := case when v_comp is not null then 'mail:comp:' || left(v_comp, 100)
                   else 'mail:' || left(p->>'message_id', 300) end;

  -- Ya importado en un resumen (por ejemplo, un mail que se relee después): el aviso confirma ese movimiento
  select m.id into v_res
  from movimientos m
  where m.cuenta_id = v_cuenta and m.origen = 'resumen' and m.moneda = a->>'moneda'
    and abs(m.monto - v_monto) < case when v_cuotas > 1 then 1 else 0.01 end and abs(m.fecha - v_fecha) <= 5
    and not exists (select 1 from avisos av where av.movimiento_id = m.id)
  order by abs(m.fecha - v_fecha), m.id
  limit 1;
  if v_res is not null then
    update avisos set estado = 'confirmado', cuenta_id = v_cuenta, movimiento_id = v_res where id = v_aviso;
    return jsonb_build_object('estado', 'confirmado', 'aviso_id', v_aviso, 'movimiento_id', v_res);
  end if;

  -- Ya anotado a mano (misma cuenta, moneda e importe, fecha a 5 días o menos): el aviso lo confirma y no se duplica.
  -- Se queda el anotado, con su rubro y su vínculo de transferencia interna; suma el comprobante del mail.
  select m.id into v_manual
  from movimientos m
  where m.cuenta_id = v_cuenta and m.origen = 'manual' and m.moneda = a->>'moneda'
    and m.monto = v_monto and abs(m.fecha - v_fecha) <= 5
    and not exists (select 1 from avisos av where av.movimiento_id = m.id)
  order by abs(m.fecha - v_fecha), m.id
  limit 1;
  if v_manual is not null then
    update movimientos
    set comprobante = coalesce(comprobante, v_comp),
        notas = concat_ws(' · ', nullif(notas, ''), 'Confirmado por aviso de mail',
                  case when coalesce(a->>'cbu', '') <> '' then 'CBU/CVU: ' || left(a->>'cbu', 40) end)
    where id = v_manual;
    update avisos set estado = 'registrado', cuenta_id = v_cuenta, movimiento_id = v_manual where id = v_aviso;
    return jsonb_build_object('estado', 'registrado', 'aviso_id', v_aviso, 'movimiento_id', v_manual, 'anotado', true);
  end if;

  -- Transferencia entre cuentas propias: el CBU/CVU de la otra punta es de una cuenta activa
  if a->>'tipo' in ('transferencia_enviada', 'transferencia_recibida')
     and length(regexp_replace(coalesce(a->>'cbu', ''), '\D', '', 'g')) = 22 then
    select c.id into v_destino from cuentas c
    where c.activa and c.id <> v_cuenta
      and regexp_replace(coalesce(c.cbu_cvu, ''), '\D', '', 'g') = regexp_replace(a->>'cbu', '\D', '', 'g')
    limit 1;
    if v_destino is not null then
      select id into v_interna from rubros where nombre = 'Transferencia interna' and padre_id is not null;
    end if;
  end if;

  -- Transferencia que coincide con un vencimiento sin registrar (misma moneda y signo, ±1 %, ±3 días)
  if v_interna is null and a->>'tipo' in ('transferencia_enviada', 'transferencia_recibida') then
    select f.compromiso_id, f.fecha::date, f.aguinaldo, k.rubro_id, k.activo_id
      into v_k_id, v_k_fecha, v_k_agui, v_k_rubro, v_k_activo
    from v_flujo_proyectado f
    join compromisos k on k.id = f.compromiso_id
    where f.moneda = a->>'moneda' and sign(f.monto) = sign(v_monto)
      and abs(abs(f.monto) - abs(v_monto)) <= abs(f.monto) * 0.01
      and abs(f.fecha::date - v_fecha) <= 3
    order by abs(f.fecha::date - v_fecha), abs(abs(f.monto) - abs(v_monto)), f.compromiso_id
    limit 1;
  end if;

  -- Rubro por las reglas automáticas (salvo transferencias internas); si ninguna aplica, el del compromiso
  select * into rg from reglas
  where v_interna is null and modo = 'auto' and v_desc ilike patron
    and (monto_exacto is null or abs(monto_exacto) = abs(v_monto))
  order by prioridad, id
  limit 1;

  insert into movimientos (cuenta_id, plastico_id, fecha, descripcion_original, monto, moneda,
                           rubro_id, persona_id, beneficiario_id, activo_id, es_extraordinario,
                           cuota_nro, cuotas_total, comprobante, id_externo, origen, confianza,
                           estado_conciliacion, notas)
  values (v_cuenta, v_plastico, v_fecha, v_desc, v_monto, a->>'moneda',
          coalesce(v_interna, rg.rubro_id, v_k_rubro), v_persona, rg.beneficiario_id, coalesce(rg.activo_id, v_k_activo), coalesce(rg.es_extraordinario, false),
          case when v_cuotas > 1 then 1 end, case when v_cuotas > 1 then v_cuotas end,
          v_comp, v_id_ext, 'mail', 'probable', 'pendiente',
          concat_ws(' · ',
            case when v_cuotas > 1 then format('Compra de %s %s en %s cuotas', a->>'moneda', abs((a->>'monto')::numeric), v_cuotas) end,
            case when coalesce(a->>'destinatario', '') <> '' then 'Destinatario: ' || left(a->>'destinatario', 120) end,
            case when coalesce(a->>'cbu', '') <> '' then 'CBU/CVU: ' || left(a->>'cbu', 40) end))
  on conflict (cuenta_id, id_externo) do nothing
  returning id into v_mov;

  if rg.id is not null then
    update reglas set veces_aplicada = veces_aplicada + 1 where id = rg.id;
  end if;

  -- Salida a una cuenta propia: la entrada en la cuenta de destino es la que ya esté anotada (mismo importe,
  -- fecha a 5 días o menos, sin vincular) o, si no hay, una nueva con origen mail; las dos quedan vinculadas.
  -- Cuando llegue el resumen de la cuenta de destino, la reemplaza como a cualquier movimiento de mail.
  if v_mov is not null and v_interna is not null and v_monto < 0 then
    select m.id into v_entrada
    from movimientos m
    where m.cuenta_id = v_destino and m.moneda = a->>'moneda' and m.monto = -v_monto and abs(m.fecha - v_fecha) <= 5
      and not exists (select 1 from transferencias_internas t where t.mov_entrada_id = m.id)
      and (m.origen in ('manual', 'mail') or m.rubro_id = v_interna)
    order by abs(m.fecha - v_fecha), m.id
    limit 1;
    if v_entrada is null then
      insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, rubro_id, persona_id,
                               id_externo, origen, confianza, estado_conciliacion, notas)
      select v_destino, v_fecha, left('Transferencia de ' || c.alias, 300), -v_monto, a->>'moneda', v_interna, v_persona,
             v_id_ext || ':entrada', 'mail', 'probable', 'conciliado', 'Entrada de una transferencia avisada por mail'
      from cuentas c where c.id = v_cuenta
      on conflict (cuenta_id, id_externo) do nothing
      returning id into v_entrada;
    end if;
    insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo)
    values (v_mov, v_entrada, 'transferencia')
    on conflict do nothing;
    if v_entrada is not null then
      update movimientos set estado_conciliacion = 'conciliado' where id in (v_mov, v_entrada);
    end if;
  end if;

  -- Transferencia que paga o cobra un compromiso: ese vencimiento deja de proyectarse
  if v_mov is not null and v_k_id is not null then
    insert into compromisos_registrados (compromiso_id, fecha, aguinaldo, movimiento_id)
    values (v_k_id, v_k_fecha, v_k_agui, v_mov)
    on conflict (compromiso_id, fecha, aguinaldo) do nothing;
  end if;

  update avisos set estado = 'registrado', cuenta_id = v_cuenta, movimiento_id = v_mov where id = v_aviso;
  return jsonb_build_object('estado', 'registrado', 'aviso_id', v_aviso, 'movimiento_id', v_mov,
                            'compromiso_id', v_k_id, 'interna', v_destino is not null);
end;
$$;

-- 7. Alertas
create or replace function alertas_calcular()
returns table (clave text, tipo text, fecha date, titulo text, detalle text, monto numeric, moneda text)
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg   config_alertas;
  v_mep numeric;
  v_mes date := (date_trunc('month', current_date) - interval '1 month')::date;
begin
  if not (es_autorizado() or exists (select 1 from capturadores c where c.user_id = auth.uid())) then
    raise exception 'No autorizado';
  end if;
  select * into cfg from config_alertas where id = 1;
  if cfg.id is null or not cfg.activas then
    return;
  end if;
  select venta into v_mep from tipos_cambio where tipos_cambio.tipo = 'mep' order by tipos_cambio.fecha desc limit 1;

  -- Gasto grande registrado en los últimos 3 días (salvo el pago de un vencimiento ya cargado como compromiso: era esperado)
  return query
  select 'gasto:' || m.id, 'gasto_grande', m.fecha, 'Gasto grande: ' || m.descripcion_original,
         c.alias || coalesce(' · ' || r.nombre, ''), m.monto, m.moneda
  from movimientos m
  join cuentas c on c.id = m.cuenta_id
  left join rubros r on r.id = m.rubro_id
  where m.creado_en > now() - interval '3 days' and m.fecha >= current_date - 7 and m.monto < 0
    and coalesce(r.tipo, 'gasto') = 'gasto'
    and abs(m.monto * case when m.moneda = 'USD' then coalesce(m.tipo_cambio, v_mep, 0) else 1 end) >= cfg.gasto_grande
    and not exists (select 1 from compromisos_registrados cr where cr.movimiento_id = m.id)
    and not (m.origen = 'resumen' and exists (select 1 from avisos av where av.movimiento_id = m.id));

  -- Vencimientos de los próximos días
  return query
  select 'vto:' || f.compromiso_id || ':' || f.fecha, 'vencimiento', f.fecha::date,
         'Vence el ' || to_char(f.fecha, 'DD/MM') || ': ' || f.descripcion, null::text, f.monto, f.moneda
  from v_flujo_proyectado f
  where f.fecha between current_date and current_date + cfg.dias_vencimiento and f.monto < 0;

  -- Saldo en pesos proyectado que queda en rojo en los próximos 7 días: parte de la liquidez de hoy y
  -- suma día por día los ingresos y egresos comprometidos (igual que el saldo proyectado de Lo que viene);
  -- los vencidos sin registrar ni omitir cuentan como si se cobraran o pagaran hoy
  return query
  with li as (
    select coalesce(sum(v.saldo_estimado), 0) as total from v_saldo_vivo v
    join cuentas c on c.id = v.cuenta_id
    where c.tipo <> 'tarjeta_credito' and v.moneda = 'ARS'
  ), dias as (
    select current_date as dia, 0::numeric as neto
    union all
    select greatest(f.fecha::date, current_date), f.monto from v_flujo_proyectado f
    where f.moneda = 'ARS' and f.fecha <= current_date + 7
  ), serie as (
    select d.dia, li.total + sum(sum(d.neto)) over (order by d.dia) as saldo
    from dias d, li group by d.dia, li.total
  ), peor as (
    select s.dia, s.saldo from serie s where s.saldo < 0 order by s.saldo, s.dia limit 1
  )
  select 'fondos:' || to_char(current_date, 'IYYY-IW'), 'saldo_insuficiente', p.dia,
         'La liquidez en pesos no alcanza para los vencimientos de los próximos 7 días',
         format('El %s el saldo proyectado llega a −$ %s, contando los ingresos esperados y los vencidos sin registrar (hoy hay $ %s disponibles)',
                to_char(p.dia, 'DD/MM'), to_char(-p.saldo, 'FM999G999G999G990'), to_char(li.total, 'FM999G999G999G990')),
         p.saldo, 'ARS'
  from peor p, li;

  -- Compromisos mensuales del mes anterior: pagados dos veces o sin pagar
  -- (solo si ya se importó un resumen que cubre todo ese mes)
  return query
  select 'rec:' || k.id || ':' || to_char(v_mes, 'YYYY-MM') || ':' || case when x.n >= 2 then 'dup' else 'falta' end,
         case when x.n >= 2 then 'pago_duplicado' else 'pago_faltante' end, current_date,
         case when x.n >= 2 then 'Posible pago duplicado en ' else 'No encontré el pago de ' end
           || to_char(v_mes, 'MM/YYYY') || ': ' || k.descripcion,
         format('%s pagos por un importe parecido a %s', x.n, to_char(aj.monto, 'FM999G999G999G990')), -aj.monto, k.moneda
  from compromisos k
  cross join lateral (
    select abs(k.monto) * case when k.indexacion = 'ipc' and k.ultimo_ajuste is not null
                               then factor_ipc(k.ultimo_ajuste, v_mes, coalesce(k.ajuste_cada, 3)) else 1 end as monto
  ) aj
  cross join lateral (
    select count(*) as n from movimientos m
    where m.rubro_id = k.rubro_id and m.moneda = k.moneda and m.monto < 0
      and (k.cuenta_id is null or m.cuenta_id = k.cuenta_id) and m.confianza <> 'sugerido'
      and date_trunc('month', m.fecha) = v_mes
      and abs(abs(m.monto) - aj.monto) <= aj.monto * 0.15
  ) x
  where k.activo and k.frecuencia = 'mensual' and k.rubro_id is not null and k.monto < 0
    and k.fecha_proxima <= v_mes and (k.fecha_fin is null or k.fecha_fin >= v_mes)
    and exists (select 1 from documentos d
                where d.periodo_hasta >= (v_mes + interval '1 month' - interval '1 day')::date
                  and (k.cuenta_id is null or d.cuenta_id = k.cuenta_id))
    and (x.n >= 2 or (x.n = 0 and not exists (select 1 from compromisos_registrados cr
                                              where cr.compromiso_id = k.id and date_trunc('month', cr.fecha) = v_mes)));

  -- Resúmenes de la bandeja que no se pudieron guardar solos
  return query
  select 'bandeja:' || b.id || ':' || coalesce(b.nota, ''), 'bandeja', b.creado_en::date,
         'Resumen para revisar en Importar: ' || coalesce(b.nombre, 'PDF'), b.nota, null::numeric, null::text
  from bandeja b
  where b.estado = 'revisar';
end;
$$;

-- 8. Borrar un movimiento anotado a mano o llegado por mail
create or replace function borrar_movimiento(p_id bigint)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  m movimientos;
begin
  if not es_autorizado() then
    raise exception 'No autorizado';
  end if;
  select * into m from movimientos where id = p_id;
  if m.id is null then
    raise exception 'El movimiento ya no existe';
  end if;
  if m.origen not in ('manual', 'mail') or (m.origen = 'manual' and coalesce(m.id_externo, '') not like 'manual:%') then
    raise exception 'Solo se pueden borrar movimientos anotados a mano o llegados por mail';
  end if;
  -- La entrada automática en la cuenta de destino de una transferencia avisada por mail
  if m.origen = 'mail' then
    delete from movimientos e where e.origen = 'mail' and e.id_externo = m.id_externo || ':entrada';
  end if;
  -- La otra punta de una transferencia anotada a mano ("Entre mis cuentas")
  delete from movimientos e
  using transferencias_internas t
  where e.origen = 'manual' and e.id_externo like 'manual:%'
    and ((t.mov_salida_id = m.id and e.id = t.mov_entrada_id) or (t.mov_entrada_id = m.id and e.id = t.mov_salida_id));
  update avisos set estado = 'descartado' where movimiento_id = m.id;
  -- El registro del vencimiento que pagaba se borra en cascada: vuelve a proyectarse
  delete from movimientos where id = m.id;
  return jsonb_build_object('borrado', p_id);
end;
$$;

-- 9. Datos
-- Pago de tarjeta que quedó con un rubro de gasto: pasa a "Pago de tarjeta" y se empareja con el débito de la cuenta
do $$
declare
  v_pago bigint := (select id from rubros where nombre = 'Pago de tarjeta' and padre_id is not null);
  v_t    bigint;
begin
  select t.id into v_t
  from transferencias_internas t
  join movimientos s on s.id = t.mov_salida_id
  join movimientos e on e.id = 202
  where t.mov_entrada_id is null and t.tipo = 'pago_tarjeta' and s.moneda = e.moneda and s.monto = -e.monto
    and abs(s.fecha - e.fecha) <= 5 and e.descripcion_original ilike 'su pago%' and e.rubro_id is distinct from v_pago;
  if v_t is not null then
    update movimientos set rubro_id = v_pago where id = 202;
    update transferencias_internas set mov_entrada_id = 202 where id = v_t;
    update movimientos set estado_conciliacion = 'conciliado'
    where id in (202, (select mov_salida_id from transferencias_internas where id = v_t));
  end if;
end $$;

-- Registro de un vencimiento sin movimiento, con una fecha que no es de ninguna cuota pagada
delete from compromisos_registrados where id = 1 and movimiento_id is null and not omitido and fecha = '2027-01-03';

-- Transferencias de mail ya emparejadas que seguían como pendientes
update movimientos m set estado_conciliacion = 'conciliado'
where m.estado_conciliacion = 'pendiente'
  and exists (select 1 from transferencias_internas t where t.mov_entrada_id is not null and (t.mov_salida_id = m.id or t.mov_entrada_id = m.id));
