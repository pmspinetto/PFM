-- =====================================================================
-- Alerta de liquidez coherente con Lo que viene: antes comparaba la liquidez de hoy con todos los
-- egresos de los próximos 7 días sin contar los ingresos esperados; ahora avisa solo si el saldo
-- proyectado día por día (liquidez + ingresos - egresos) queda en rojo, y dice qué día.
-- No modifica datos.
-- =====================================================================

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

  -- Saldo en pesos proyectado que queda en rojo en los próximos 7 días: parte de la liquidez de hoy y
  -- suma día por día los ingresos y egresos comprometidos (igual que el saldo proyectado de Lo que viene)
  return query
  with li as (
    select coalesce(sum(v.saldo_estimado), 0) as total from v_saldo_vivo v
    join cuentas c on c.id = v.cuenta_id
    where c.tipo <> 'tarjeta_credito' and v.moneda = 'ARS'
  ), dias as (
    select current_date as dia, 0::numeric as neto
    union all
    select f.fecha::date, f.monto from v_flujo_proyectado f
    where f.moneda = 'ARS' and f.fecha between current_date and current_date + 7
  ), serie as (
    select d.dia, li.total + sum(sum(d.neto)) over (order by d.dia) as saldo
    from dias d, li group by d.dia, li.total
  ), peor as (
    select s.dia, s.saldo from serie s where s.saldo < 0 order by s.saldo, s.dia limit 1
  )
  select 'fondos:' || to_char(current_date, 'IYYY-IW'), 'saldo_insuficiente', p.dia,
         'La liquidez en pesos no alcanza para los vencimientos de los próximos 7 días',
         format('El %s el saldo proyectado llega a −$ %s, contando los ingresos esperados (hoy hay $ %s disponibles)',
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
