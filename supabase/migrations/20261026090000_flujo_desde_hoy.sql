-- =====================================================================
-- Flujo proyectado: los compromisos mensuales y anuales se proyectan hasta 12 meses
-- desde hoy (antes, hasta 12 meses desde su primera fecha, y dejaban de proyectarse).
-- No modifica datos: reemplaza la vista.
-- =====================================================================

create or replace view v_flujo_proyectado with (security_invoker = on) as
select c.id as compromiso_id, c.descripcion, c.tipo, c.indexacion,
       gs::date as fecha, c.monto, c.moneda
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
