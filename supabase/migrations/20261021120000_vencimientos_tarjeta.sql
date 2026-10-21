-- =====================================================================
-- Vencimientos de resúmenes de tarjeta
-- - documentos guarda vencimiento, próximo cierre, próximo vencimiento y pago mínimo
-- - guardar_importacion crea los compromisos de pago de cada resumen de tarjeta
--   y recuerda el número/CBU de la cuenta cuando todavía no lo tenía
-- No modifica datos existentes: agrega columnas y reemplaza la función.
-- =====================================================================

alter table documentos
  add column if not exists vencimiento         date,
  add column if not exists proximo_cierre      date,
  add column if not exists proximo_vencimiento date,
  add column if not exists pago_minimo         numeric(18,2);

alter table compromisos
  add column if not exists documento_id bigint references documentos(id) on delete cascade;

alter table compromisos drop constraint if exists compromisos_tipo_check;
alter table compromisos add constraint compromisos_tipo_check check (tipo in (
  'cuota_tarjeta','vencimiento_tarjeta','prestamo','servicio','seguro','expensas',
  'educacion','actividad','suscripcion','alquiler','cheque','otro'));

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
  on conflict (cuenta_id, fecha, moneda) do nothing;

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
    where cuenta_id = v_cuenta and moneda = r.moneda
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
  on conflict (mov_salida_id) do nothing;

  update movimientos set estado_conciliacion = 'pendiente'
  where documento_id = v_doc and rubro_id = any(v_internos);

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
    'emparejadas', v_pares);
end;
$$;

revoke execute on function guardar_importacion(jsonb) from anon;
grant  execute on function guardar_importacion(jsonb) to authenticated;
