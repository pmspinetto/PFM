-- =====================================================================
-- Saldos del día, efectivo y dólar automático
-- - saldos.fuente: 'resumen' (confirmado), 'informado' (cargado a mano desde el home
--   banking) o 'arqueo' (efectivo contado). v_saldo_vivo expone la fuente; el resumen
--   reemplaza un saldo informado del mismo día.
-- - v_saldos_control: por cuenta, cuánto del saldo informado no se explica todavía con
--   el último resumen + los movimientos cargados.
-- - registrar_arqueo: compara lo contado con lo esperado y registra la diferencia como
--   "Efectivo no identificado".
-- - guardar_importacion: cada retiro o depósito de efectivo genera su contraparte en la caja.
-- - registrar_tipos_cambio: cotizaciones diarias (las carga el script de Gmail; también
--   sirve de latido para que el proyecto no se pause).
-- Datos: agrega el rubro "Efectivo no identificado" (grupo Varios) si no existe.
-- =====================================================================

create or replace view v_saldo_vivo with (security_invoker = on) as
with ultimo as (
  select distinct on (cuenta_id, moneda) cuenta_id, moneda, fecha, saldo, fuente
  from saldos order by cuenta_id, moneda, fecha desc
)
select c.alias, u.moneda, u.fecha as confirmado_al, u.saldo as saldo_confirmado,
       coalesce(sum(m.monto), 0)    as movimientos_posteriores,
       count(m.id)                  as cant_movimientos,
       u.saldo + coalesce(sum(m.monto), 0) as saldo_estimado,
       u.cuenta_id, u.fuente
from ultimo u
join cuentas c on c.id = u.cuenta_id
left join movimientos m on m.cuenta_id = u.cuenta_id and m.moneda = u.moneda and m.fecha > u.fecha
group by c.alias, u.moneda, u.fecha, u.saldo, u.cuenta_id, u.fuente;

create or replace view v_saldos_control with (security_invoker = on) as
with inf as (
  select distinct on (cuenta_id, moneda) cuenta_id, moneda, fecha, saldo
  from saldos where fuente = 'informado' order by cuenta_id, moneda, fecha desc
), res as (
  select distinct on (s.cuenta_id, s.moneda) s.cuenta_id, s.moneda, s.fecha, s.saldo
  from saldos s join inf i on i.cuenta_id = s.cuenta_id and i.moneda = s.moneda and s.fecha < i.fecha
  where s.fuente = 'resumen' order by s.cuenta_id, s.moneda, s.fecha desc
)
select i.cuenta_id, i.moneda, i.fecha as informado_al, i.saldo as saldo_informado,
       r.fecha as resumen_al, r.saldo as saldo_resumen,
       r.saldo + coalesce(mv.suma, 0) as saldo_esperado,
       i.saldo - (r.saldo + coalesce(mv.suma, 0)) as sin_explicar
from inf i
left join res r on r.cuenta_id = i.cuenta_id and r.moneda = i.moneda
left join lateral (
  select sum(m.monto) as suma from movimientos m
  where m.cuenta_id = i.cuenta_id and m.moneda = i.moneda and m.fecha > r.fecha and m.fecha <= i.fecha
) mv on true;

insert into rubros (nombre, padre_id, tipo)
select 'Efectivo no identificado', g.id, g.tipo
from rubros g
where g.nombre = 'Varios' and g.padre_id is null
  and not exists (select 1 from rubros x where x.nombre = 'Efectivo no identificado');

create or replace function registrar_arqueo(p_cuenta bigint, p_fecha date, p_contado numeric)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_mon     text;
  v_persona bigint;
  v_base    record;
  v_teorico numeric;
  v_dif     numeric;
  v_arqueo  bigint;
begin
  if not es_autorizado() then
    raise exception 'No autorizado';
  end if;
  select moneda, persona_id into v_mon, v_persona from cuentas where id = p_cuenta and tipo = 'caja_efectivo';
  if v_mon is null then
    raise exception 'La cuenta no es una caja de efectivo';
  end if;

  select fecha, saldo into v_base from saldos
  where cuenta_id = p_cuenta and moneda = v_mon and fecha <= p_fecha
  order by fecha desc limit 1;
  if v_base.fecha is null then
    v_teorico := p_contado;   -- primer arqueo: fija el punto de partida
  else
    select v_base.saldo + coalesce(sum(monto), 0) into v_teorico from movimientos
    where cuenta_id = p_cuenta and moneda = v_mon and fecha > v_base.fecha and fecha <= p_fecha;
  end if;
  v_dif := round(p_contado - v_teorico, 2);

  insert into arqueos (cuenta_id, fecha, monto_contado, saldo_teorico)
  values (p_cuenta, p_fecha, p_contado, v_teorico)
  returning id into v_arqueo;

  if v_dif <> 0 then
    insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, rubro_id, persona_id,
                             id_externo, origen, confianza, estado_conciliacion)
    values (p_cuenta, p_fecha, 'Diferencia de arqueo', v_dif, v_mon,
            (select id from rubros where nombre = 'Efectivo no identificado' and padre_id is not null),
            v_persona, 'arqueo:' || v_arqueo, 'manual', 'confirmado', 'no_aplica');
  end if;

  insert into saldos (cuenta_id, fecha, moneda, saldo, fuente)
  values (p_cuenta, p_fecha, v_mon, p_contado, 'arqueo')
  on conflict (cuenta_id, fecha, moneda) do update set saldo = excluded.saldo, fuente = 'arqueo';

  return jsonb_build_object('teorico', v_teorico, 'contado', p_contado, 'diferencia', v_dif);
end;
$$;

revoke execute on function registrar_arqueo(bigint, date, numeric) from public, anon;
grant  execute on function registrar_arqueo(bigint, date, numeric) to authenticated;

create or replace function registrar_tipos_cambio(p jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if not (es_autorizado() or exists (select 1 from capturadores where user_id = auth.uid())) then
    raise exception 'No autorizado';
  end if;
  insert into tipos_cambio (fecha, tipo, compra, venta)
  select (x->>'fecha')::date, x->>'tipo', nullif(x->>'compra', '')::numeric, (x->>'venta')::numeric
  from jsonb_array_elements(coalesce(p->'cotizaciones', '[]'::jsonb)) x
  where x->>'tipo' in ('oficial','mep','blue','tarjeta')
    and coalesce(nullif(x->>'venta', '')::numeric, 0) > 0
  on conflict (fecha, tipo) do update set compra = excluded.compra, venta = excluded.venta;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function registrar_tipos_cambio(jsonb) from public, anon;
grant  execute on function registrar_tipos_cambio(jsonb) to authenticated;

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
  v_absorbidos jsonb := '[]';
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

  -- Avisos por mail que este resumen confirma: se reemplazan por el movimiento del resumen
  -- (misma cuenta, moneda e importe; fecha de la operación a 5 días o menos). En compras
  -- en cuotas se compara con la fecha original y se tolera $1 por el redondeo de la cuota.
  for r in
    select m->>'id_externo' as id_externo, m->>'moneda' as moneda, (m->>'monto')::numeric as monto,
           coalesce(to_date(substring(m->>'descripcion_original' from 'compra original (\d{2}/\d{2}/\d{2})'), 'DD/MM/YY'),
                    (m->>'fecha')::date) as fecha_op
    from jsonb_array_elements(p->'movimientos') m
  loop
    select x.id, a.id as aviso_id into v_mail
    from movimientos x
    left join avisos a on a.movimiento_id = x.id
    where x.cuenta_id = v_cuenta and x.origen = 'mail' and x.moneda = r.moneda
      and abs(x.monto - r.monto) < case when coalesce(x.cuotas_total, 1) > 1 then 1 else 0.01 end
      and abs(x.fecha - r.fecha_op) <= 5
      and not exists (select 1 from jsonb_array_elements(v_absorbidos) e where (e->>'mov')::bigint = x.id)
    order by abs(x.fecha - r.fecha_op), x.id
    limit 1;
    if v_mail.id is not null then
      v_absorbidos := v_absorbidos || jsonb_build_object('mov', v_mail.id, 'aviso', v_mail.aviso_id, 'id_externo', r.id_externo);
    end if;
  end loop;

  delete from movimientos
  where id in (select (e->>'mov')::bigint from jsonb_array_elements(v_absorbidos) e);

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
      and fecha > r.fi and fecha <= r.ff;

    if abs(v_dif) >= 0.01 then
      raise exception 'La cuenta no concilia en %: diferencia de % (¿hay movimientos cargados antes por otra vía?)',
        r.moneda, v_dif;
    end if;
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

    insert into compromisos (descripcion, tipo, cuenta_id, rubro_id, monto, moneda, indexacion,
                             frecuencia, fecha_proxima, documento_id)
    select format('Próximo resumen %s (por ahora, solo cuotas ya conocidas)', v_alias),
           'vencimiento_tarjeta', v_cuenta, v_rubro,
           -coalesce(nullif(v_tar->>'cuotas_proximo_resumen','')::numeric, 0), 'ARS',
           'estimado', 'unica', (v_tar->>'proximo_vencimiento')::date, v_doc
    where nullif(v_tar->>'proximo_vencimiento','') is not null;
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

  update movimientos set estado_conciliacion = 'pendiente'
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

  -- Reglas nuevas
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
    'absorbidos', jsonb_array_length(v_absorbidos));
end;
$$;

revoke execute on function guardar_importacion(jsonb) from anon;
grant  execute on function guardar_importacion(jsonb) to authenticated;
