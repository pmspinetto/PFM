-- =====================================================================
-- Captura por mail: ningún mail leído se descarta, transferencias y vínculo con compromisos.
-- - avisos.estado admite 'no_reconocido' (mail de un banco que ningún lector entiende),
--   'error' (falló la lectura), 'sospechoso' (no pasó la verificación de autenticidad) y
--   'duplicado' (otra copia del mismo aviso, por ejemplo redirigida por regla y reenviada a mano).
-- - registrar_aviso(p):
--   · con p.estado in (no_reconocido, error, sospechoso) solo guarda el mail (p.datos: asunto,
--     remitente, extracto del cuerpo o mensaje de error), sin crear movimientos;
--   · si un mail ya estaba como no_reconocido o error y ahora se reconoce, lo actualiza;
--   · un aviso con número de comprobante ya registrado en el mismo banco queda 'duplicado';
--   · el movimiento usa id_externo 'mail:comp:<comprobante>' cuando hay comprobante;
--   · transferencias a una cuenta propia (CBU/CVU de destino de otra cuenta activa): rubro
--     "Transferencia interna" y queda en tránsito hasta que aparezca la entrada;
--   · transferencias que coinciden con un vencimiento de v_flujo_proyectado (misma moneda y
--     signo, importe ±1 %, fecha ±3 días, sin registrar) lo registran en compromisos_registrados
--     y, si ninguna regla les da rubro, toman el rubro y el bien del compromiso.
-- No modifica datos existentes.
-- =====================================================================

alter table avisos drop constraint if exists avisos_estado_check;
alter table avisos add constraint avisos_estado_check check (estado in (
  'pendiente','registrado','sin_cuenta','confirmado','descartado','no_reconocido','error','sospechoso','duplicado'));

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

  -- Salida a una cuenta propia: queda en tránsito hasta que aparezca la entrada
  if v_mov is not null and v_interna is not null and v_monto < 0 then
    insert into transferencias_internas (mov_salida_id, mov_entrada_id, tipo)
    values (v_mov, null, 'transferencia')
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
