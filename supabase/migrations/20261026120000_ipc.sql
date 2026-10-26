-- =====================================================================
-- Compromisos que ajustan por IPC
-- - indices: variación mensual del IPC (la carga el script de Gmail desde el BCRA;
--   se precargan los últimos 24 meses publicados, que son datos públicos).
-- - compromisos: indexacion 'ipc', cada cuántos meses ajusta (ajuste_cada) y el mes del
--   último ajuste (ultimo_ajuste).
-- - factor_ipc(): en cada mes de ajuste multiplica (1 + IPC) de los meses que van del 4.º
--   al 2.º anterior (con ajuste trimestral: octubre usa junio, julio y agosto). Los meses
--   todavía no publicados se estiman con el promedio de los últimos 3 publicados.
-- - v_flujo_proyectado y alertas_calcular usan el monto ajustado.
-- Datos: agrega la tabla de índices con valores públicos; no modifica datos existentes.
-- =====================================================================

create table if not exists indices (
  mes        date not null,             -- primer día del mes
  tipo       text not null check (tipo in ('ipc')),
  variacion  numeric(8,4) not null,     -- % mensual
  primary key (mes, tipo)
);
alter table indices enable row level security;
drop policy if exists acceso_autorizado on indices;
create policy acceso_autorizado on indices for all to authenticated
  using (es_autorizado()) with check (es_autorizado());

insert into indices (mes, tipo, variacion)
select v.mes::date, 'ipc', v.variacion from (values
  ('2024-10-01', 2.7),
  ('2024-11-01', 2.4),
  ('2024-12-01', 2.7),
  ('2025-01-01', 2.2),
  ('2025-02-01', 2.4),
  ('2025-03-01', 3.7),
  ('2025-04-01', 2.8),
  ('2025-05-01', 1.5),
  ('2025-06-01', 1.6),
  ('2025-07-01', 1.9),
  ('2025-08-01', 1.9),
  ('2025-09-01', 2.1),
  ('2025-10-01', 2.3),
  ('2025-11-01', 2.5),
  ('2025-12-01', 2.8),
  ('2026-01-01', 2.9),
  ('2026-02-01', 2.9),
  ('2026-03-01', 3.4),
  ('2026-04-01', 2.6),
  ('2026-05-01', 2.1),
  ('2026-06-01', 1.9),
  ('2026-07-01', 2.1),
  ('2026-08-01', 1.7),
  ('2026-09-01', 1.9)
) as v(mes, variacion)
on conflict (mes, tipo) do nothing;

alter table compromisos drop constraint if exists compromisos_indexacion_check;
alter table compromisos add constraint compromisos_indexacion_check
  check (indexacion in ('ninguna','uva','estimado','ipc'));
alter table compromisos
  add column if not exists ajuste_cada   int check (ajuste_cada between 1 and 12),
  add column if not exists ultimo_ajuste date;

create or replace function factor_ipc(p_ultimo date, p_mes date, p_cada int)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  f   numeric := 1;
  a   date := (date_trunc('month', p_ultimo) + make_interval(months => p_cada))::date;
  v   numeric;
  est numeric;
begin
  select avg(variacion) into est
  from (select variacion from indices where tipo = 'ipc' order by mes desc limit 3) x;
  while a <= date_trunc('month', p_mes)::date loop
    for k in 2..(p_cada + 1) loop
      select variacion into v from indices
      where tipo = 'ipc' and mes = (a - make_interval(months => k))::date;
      f := f * (1 + coalesce(v, est, 0) / 100);
    end loop;
    a := (a + make_interval(months => p_cada))::date;
  end loop;
  return f;
end;
$$;

create or replace view v_flujo_proyectado with (security_invoker = on) as
select c.id as compromiso_id, c.descripcion, c.tipo, c.indexacion,
       gs::date as fecha,
       round(c.monto * case when c.indexacion = 'ipc' and c.ultimo_ajuste is not null
                            then factor_ipc(c.ultimo_ajuste, gs::date, coalesce(c.ajuste_cada, 3)) else 1 end, 2)::numeric(18,2) as monto,
       c.moneda
from compromisos c
cross join lateral generate_series(
  c.fecha_proxima,
  case when c.frecuencia = 'unica' then c.fecha_proxima
       else least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months') end,
  case c.frecuencia when 'mensual' then interval '1 month'
                    when 'anual'   then interval '1 year'
                    else interval '100 years' end
) gs
where c.activo;

create or replace function registrar_tipos_cambio(p jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
  m int;
begin
  if not (es_autorizado() or exists (select 1 from capturadores where user_id = auth.uid())) then
    raise exception 'No autorizado';
  end if;
  insert into tipos_cambio (fecha, tipo, compra, venta)
  select (x->>'fecha')::date, x->>'tipo', nullif(x->>'compra', '')::numeric, (x->>'venta')::numeric
  from jsonb_array_elements(coalesce(p->'cotizaciones', '[]'::jsonb)) x
  where x->>'tipo' in ('oficial','mep','blue','tarjeta','uva')
    and coalesce(nullif(x->>'venta', '')::numeric, 0) > 0
  on conflict (fecha, tipo) do update set compra = excluded.compra, venta = excluded.venta;
  get diagnostics n = row_count;
  insert into indices (mes, tipo, variacion)
  select date_trunc('month', (x->>'mes')::date)::date, 'ipc', (x->>'variacion')::numeric
  from jsonb_array_elements(coalesce(p->'indices', '[]'::jsonb)) x
  where x->>'tipo' = 'ipc' and nullif(x->>'variacion', '') is not null
  on conflict (mes, tipo) do update set variacion = excluded.variacion;
  get diagnostics m = row_count;
  return n + m;
end;
$$;

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
         format('%s pagos por un importe parecido a %s', x.n, to_char(aj.monto, 'FM999G999G999G990')), -aj.monto, k.moneda
  from compromisos k
  cross join lateral (
    select abs(k.monto) * case when k.indexacion = 'ipc' and k.ultimo_ajuste is not null
                               then factor_ipc(k.ultimo_ajuste, v_mes, coalesce(k.ajuste_cada, 3)) else 1 end as monto
  ) aj
  cross join lateral (
    select count(*) as n from movimientos m
    where m.rubro_id = k.rubro_id and m.moneda = k.moneda and m.monto < 0
      and date_trunc('month', m.fecha) = v_mes
      and abs(abs(m.monto) - aj.monto) <= aj.monto * 0.15
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

