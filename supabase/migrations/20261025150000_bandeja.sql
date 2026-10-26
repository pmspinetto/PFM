-- =====================================================================
-- Bandeja de resúmenes que llegan por mail con el PDF adjunto
-- - Storage: carpeta privada "bandeja". El usuario de captura solo puede subir; leer y
--   borrar, solo los usuarios autorizados.
-- - bandeja: un registro por PDF (hash único para no repetir), con su estado.
-- - registrar_bandeja(jsonb): lo usa el script de Gmail después de subir el archivo.
-- - alertas_calcular(): suma una alerta por cada resumen de la bandeja que necesita revisión.
-- Datos: crea la carpeta de Storage.
-- =====================================================================

create or replace function es_capturador() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from capturadores where user_id = auth.uid());
$$;

insert into storage.buckets (id, name, public) values ('bandeja', 'bandeja', false)
on conflict (id) do nothing;

drop policy if exists bandeja_subir on storage.objects;
drop policy if exists bandeja_leer on storage.objects;
drop policy if exists bandeja_borrar on storage.objects;
create policy bandeja_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'bandeja' and (es_autorizado() or es_capturador()));
create policy bandeja_leer on storage.objects for select to authenticated
  using (bucket_id = 'bandeja' and es_autorizado());
create policy bandeja_borrar on storage.objects for delete to authenticated
  using (bucket_id = 'bandeja' and es_autorizado());

create table if not exists bandeja (
  id            bigint generated always as identity primary key,
  hash          text not null unique,        -- SHA-256 del PDF
  archivo_path  text not null,               -- ruta dentro de la carpeta "bandeja"
  nombre        text,
  remitente     text,
  asunto        text,
  recibido      timestamptz,
  estado        text not null default 'pendiente' check (estado in ('pendiente','revisar','importado','descartado')),
  nota          text,
  creado_en     timestamptz not null default now()
);
alter table bandeja enable row level security;
drop policy if exists acceso_autorizado on bandeja;
create policy acceso_autorizado on bandeja for all to authenticated
  using (es_autorizado()) with check (es_autorizado());

create or replace function registrar_bandeja(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if not (es_autorizado() or es_capturador()) then
    raise exception 'No autorizado';
  end if;
  if coalesce(p->>'hash', '') !~ '^[0-9a-f]{64}$' or coalesce(p->>'archivo_path', '') = '' then
    raise exception 'Datos incompletos';
  end if;
  insert into bandeja (hash, archivo_path, nombre, remitente, asunto, recibido)
  values (p->>'hash', left(p->>'archivo_path', 300), left(p->>'nombre', 300), left(p->>'remitente', 300),
          left(p->>'asunto', 300), nullif(p->>'recibido', '')::timestamptz)
  on conflict (hash) do nothing
  returning id into v_id;
  return jsonb_build_object('estado', case when v_id is null then 'duplicado' else 'registrado' end, 'id', v_id);
end;
$$;

revoke execute on function registrar_bandeja(jsonb) from public, anon;
grant  execute on function registrar_bandeja(jsonb) to authenticated;
revoke execute on function es_capturador() from public, anon;
grant  execute on function es_capturador() to authenticated;

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

  -- Gasto grande registrado en los últimos 3 días
  return query
  select 'gasto:' || m.id, 'gasto_grande', m.fecha, 'Gasto grande: ' || m.descripcion_original,
         c.alias || coalesce(' · ' || r.nombre, ''), m.monto, m.moneda
  from movimientos m
  join cuentas c on c.id = m.cuenta_id
  left join rubros r on r.id = m.rubro_id
  where m.creado_en > now() - interval '3 days' and m.monto < 0
    and coalesce(r.tipo, 'gasto') = 'gasto'
    and abs(m.monto * case when m.moneda = 'USD' then coalesce(m.tipo_cambio, v_mep, 0) else 1 end) >= cfg.gasto_grande;

  -- Vencimientos de los próximos días
  return query
  select 'vto:' || f.compromiso_id || ':' || f.fecha, 'vencimiento', f.fecha::date,
         'Vence el ' || to_char(f.fecha, 'DD/MM') || ': ' || f.descripcion, null::text, f.monto, f.moneda
  from v_flujo_proyectado f
  where f.fecha between current_date and current_date + cfg.dias_vencimiento and f.monto < 0;

  -- Liquidez en pesos que no alcanza para los vencimientos de los próximos 7 días
  return query
  with eg as (
    select coalesce(-sum(f.monto), 0) as total from v_flujo_proyectado f
    where f.moneda = 'ARS' and f.monto < 0 and f.fecha between current_date and current_date + 7
  ), li as (
    select coalesce(sum(v.saldo_estimado), 0) as total from v_saldo_vivo v
    join cuentas c on c.id = v.cuenta_id
    where c.tipo <> 'tarjeta_credito' and v.moneda = 'ARS'
  )
  select 'fondos:' || to_char(current_date, 'IYYY-IW'), 'saldo_insuficiente', current_date,
         'La liquidez en pesos no alcanza para los vencimientos de los próximos 7 días',
         format('Vencen $ %s y hay $ %s disponibles', to_char(eg.total, 'FM999G999G999G990'), to_char(li.total, 'FM999G999G999G990')),
         li.total - eg.total, 'ARS'
  from eg, li
  where eg.total > li.total;

  -- Compromisos mensuales del mes anterior: pagados dos veces o sin pagar
  -- (solo si ya se importó un resumen que cubre todo ese mes)
  return query
  select 'rec:' || k.id || ':' || to_char(v_mes, 'YYYY-MM') || ':' || case when x.n >= 2 then 'dup' else 'falta' end,
         case when x.n >= 2 then 'pago_duplicado' else 'pago_faltante' end, current_date,
         case when x.n >= 2 then 'Posible pago duplicado en ' else 'No encontré el pago de ' end
           || to_char(v_mes, 'MM/YYYY') || ': ' || k.descripcion,
         format('%s pagos por un importe parecido a %s', x.n, to_char(abs(k.monto), 'FM999G999G999G990')), k.monto, k.moneda
  from compromisos k
  cross join lateral (
    select count(*) as n from movimientos m
    where m.rubro_id = k.rubro_id and m.moneda = k.moneda and m.monto < 0
      and date_trunc('month', m.fecha) = v_mes
      and abs(abs(m.monto) - abs(k.monto)) <= abs(k.monto) * 0.15
  ) x
  where k.activo and k.frecuencia = 'mensual' and k.rubro_id is not null and k.monto < 0
    and k.fecha_proxima <= v_mes
    and exists (select 1 from documentos d
                where d.periodo_hasta >= (v_mes + interval '1 month' - interval '1 day')::date
                  and (k.cuenta_id is null or d.cuenta_id = k.cuenta_id))
    and (x.n >= 2 or x.n = 0);

  -- Resúmenes de la bandeja que no se pudieron guardar solos
  return query
  select 'bandeja:' || b.id || ':' || coalesce(b.nota, ''), 'bandeja', b.creado_en::date,
         'Resumen para revisar en Importar: ' || coalesce(b.nombre, 'PDF'), b.nota, null::numeric, null::text
  from bandeja b
  where b.estado = 'revisar';
end;
$$;

