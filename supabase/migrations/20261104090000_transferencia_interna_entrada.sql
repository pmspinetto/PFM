-- =====================================================================
-- registrar_aviso: una transferencia avisada por mail a una cuenta propia (CBU/CVU de destino de otra
-- cuenta activa) anota también la entrada en la cuenta de destino, vinculada a la salida. Si la entrada
-- ya estaba anotada (mismo importe, fecha a 5 días o menos, sin vincular), se vincula esa.
-- Antes quedaba solo la salida "en tránsito" y la cuenta de destino (por ejemplo Mercado Pago, que no
-- manda avisos) no subía hasta importar su resumen.
-- Modifica datos: completa la entrada de las transferencias internas de mail que siguen en tránsito,
-- salvo cuando ya hay una transferencia anotada a mano entre esas mismas cuentas a un día o menos
-- (puede ser la misma operación cargada con otro importe: queda para revisar).
-- =====================================================================

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
    where avisos.estado in ('no_reconocido', 'error')
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
    order by abs(m.fecha - v_fecha), m.id
    limit 1;
    if v_entrada is null then
      insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, rubro_id, persona_id,
                               id_externo, origen, confianza, estado_conciliacion, notas)
      select v_destino, v_fecha, left('Transferencia de ' || c.alias, 300), -v_monto, a->>'moneda', v_interna, v_persona,
             v_id_ext || ':entrada', 'mail', 'probable', 'pendiente', 'Entrada de una transferencia avisada por mail'
      from cuentas c where c.id = v_cuenta
      on conflict (cuenta_id, id_externo) do nothing
      returning id into v_entrada;
    end if;
    insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo)
    values (v_mov, v_entrada, 'transferencia')
    on conflict do nothing;
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

-- Transferencias internas de mail que siguen en tránsito: se completa la entrada en la cuenta de destino
create temporary table entradas_faltantes as
select t.id as tid, s.id as salida, s.cuenta_id as origen, s.fecha, s.moneda, -s.monto as monto, s.rubro_id,
       s.persona_id, s.id_externo, d.id as destino, o.alias as alias_origen
from transferencias_internas t
join movimientos s on s.id = t.mov_salida_id and s.origen = 'mail'
join cuentas o on o.id = s.cuenta_id
join lateral (
  select c.id from cuentas c
  where c.activa and c.id <> s.cuenta_id
    and regexp_replace(coalesce(c.cbu_cvu, ''), '\D', '', 'g') = regexp_replace(substring(s.notas from 'CBU/CVU: ([0-9 ]+)'), '\D', '', 'g')
  limit 1
) d on true
where t.mov_entrada_id is null
  and not exists (select 1 from transferencias_internas x
                  join movimientos ms on ms.id = x.mov_salida_id and ms.origen = 'manual' and ms.cuenta_id = s.cuenta_id
                  join movimientos me on me.id = x.mov_entrada_id and me.cuenta_id = d.id
                  where abs(ms.fecha - s.fecha) <= 1);

insert into movimientos (cuenta_id, fecha, descripcion_original, monto, moneda, rubro_id, persona_id,
                         id_externo, origen, confianza, estado_conciliacion, notas)
select destino, fecha, left('Transferencia de ' || alias_origen, 300), monto, moneda, rubro_id, persona_id,
       id_externo || ':entrada', 'mail', 'probable', 'pendiente', 'Entrada de una transferencia avisada por mail'
from entradas_faltantes
on conflict (cuenta_id, id_externo) do nothing;

update transferencias_internas t
set mov_entrada_id = m.id
from entradas_faltantes e
join movimientos m on m.cuenta_id = e.destino and m.id_externo = e.id_externo || ':entrada'
where t.id = e.tid;

drop table entradas_faltantes;
