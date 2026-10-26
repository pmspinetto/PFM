-- =====================================================================
-- Aguinaldo (SAC) de los sueldos cargados como ingresos fijos.
-- compromisos.aguinaldo = porcentaje del sueldo mensual que se cobra de aguinaldo
-- (50 = medio sueldo; null = no cobra). v_flujo_proyectado agrega, por cada sueldo
-- mensual con aguinaldo, un ingreso estimado el 30/06 y el 18/12 (fechas límite de
-- pago de cada cuota) dentro de los 12 meses proyectados y antes de su fecha de fin.
-- Modifica datos: marca los sueldos mensuales activos ("Sueldo…") con 50 % si la
-- cuenta es del titular y 40 % si es de otro integrante (confirmado por el usuario).
-- =====================================================================

alter table compromisos add column if not exists aguinaldo numeric(5,2)
  check (aguinaldo is null or (aguinaldo > 0 and aguinaldo <= 100));

update compromisos k
set aguinaldo = case when p.tipo = 'titular' then 50 else 40 end
from cuentas c
join personas p on p.id = c.persona_id
where c.id = k.cuenta_id and k.activo and k.frecuencia = 'mensual' and k.monto > 0
  and k.descripcion ilike 'sueldo%' and k.aguinaldo is null;

create or replace view v_flujo_proyectado with (security_invoker = on) as
select c.id as compromiso_id, c.descripcion, c.tipo, c.indexacion,
       gs::date as fecha,
       round(c.monto * case when c.indexacion = 'ipc' and c.ultimo_ajuste is not null
                            then factor_ipc(c.ultimo_ajuste, gs::date, coalesce(c.ajuste_cada, 3)) else 1 end, 2)::numeric(18,2) as monto,
       c.moneda,
       false as aguinaldo
from compromisos c
cross join lateral generate_series(
  c.fecha_proxima,
  case when c.frecuencia = 'unica' then c.fecha_proxima
       else least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months') end,
  case c.frecuencia when 'mensual'    then interval '1 month'
                    when 'trimestral' then interval '3 months'
                    when 'semestral'  then interval '6 months'
                    when 'anual'      then interval '1 year'
                    else interval '100 years' end
) gs
where c.activo
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
  and a.fecha <= least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months');
