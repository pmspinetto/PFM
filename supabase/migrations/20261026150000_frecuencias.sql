-- =====================================================================
-- Compromisos cada 3 y 6 meses: frecuencias 'trimestral' y 'semestral'.
-- No modifica datos: amplía una restricción y reemplaza la vista de flujo proyectado.
-- =====================================================================

alter table compromisos drop constraint if exists compromisos_frecuencia_check;
alter table compromisos add constraint compromisos_frecuencia_check
  check (frecuencia in ('unica','mensual','trimestral','semestral','anual'));

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
  case c.frecuencia when 'mensual'    then interval '1 month'
                    when 'trimestral' then interval '3 months'
                    when 'semestral'  then interval '6 months'
                    when 'anual'      then interval '1 year'
                    else interval '100 years' end
) gs
where c.activo;

