-- =====================================================================
-- Alertas
-- - config_alertas: umbrales (una sola fila, editable desde la app).
-- - alertas_calcular(): alertas vigentes (gasto grande, vencimiento cerca, liquidez
--   insuficiente para los próximos 7 días, pago recurrente duplicado o faltante del mes
--   anterior cuando ya hay un resumen que lo cubre). La usan la app y el script de Gmail.
-- - alertas_por_enviar(): las alertas que todavía no se mandaron por mail (y las marca).
-- Datos: crea la fila de configuración con valores por defecto.
-- =====================================================================

create table if not exists config_alertas (
  id                 int primary key default 1 check (id = 1),
  activas            boolean not null default true,
  gasto_grande       numeric(18,2) not null default 300000,
  dias_vencimiento   int not null default 3
);
insert into config_alertas (id) values (1) on conflict (id) do nothing;
alter table config_alertas enable row level security;
drop policy if exists acceso_autorizado on config_alertas;
create policy acceso_autorizado on config_alertas for all to authenticated
  using (es_autorizado()) with check (es_autorizado());

-- Sin políticas: solo la usan funciones security definer
create table if not exists alertas_enviadas (
  clave      text primary key,
  enviada_en timestamptz not null default now()
);
alter table alertas_enviadas enable row level security;

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
end;
$$;

create or replace function alertas_por_enviar()
returns setof jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with a as (select * from alertas_calcular()),
  nuevas as (
    insert into alertas_enviadas (clave) select a.clave from a
    on conflict (clave) do nothing
    returning alertas_enviadas.clave
  )
  select to_jsonb(a) from a join nuevas on nuevas.clave = a.clave
  order by a.fecha;
end;
$$;

revoke execute on function alertas_calcular() from public, anon;
revoke execute on function alertas_por_enviar() from public, anon;
grant  execute on function alertas_calcular() to authenticated;
grant  execute on function alertas_por_enviar() to authenticated;
