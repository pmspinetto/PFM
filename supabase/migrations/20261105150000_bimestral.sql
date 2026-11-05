-- =====================================================================
-- Compromisos cada 2 meses: frecuencia 'bimestral' (por ejemplo, la patente).
-- No modifica datos: amplía una restricción y reemplaza la vista de flujo proyectado
-- (misma definición que en la migración de integridad, con el caso bimestral).
-- =====================================================================

alter table compromisos drop constraint if exists compromisos_frecuencia_check;
alter table compromisos add constraint compromisos_frecuencia_check
  check (frecuencia in ('unica','mensual','bimestral','trimestral','semestral','anual'));

create or replace view v_flujo_proyectado with (security_invoker = on) as
select c.id as compromiso_id, c.descripcion, c.tipo, c.indexacion,
       gs.fecha,
       round(c.monto * case when c.indexacion = 'ipc' and c.ultimo_ajuste is not null
                            then factor_ipc(c.ultimo_ajuste, gs.fecha, coalesce(c.ajuste_cada, 3)) else 1 end, 2)::numeric(18,2) as monto,
       c.moneda,
       false as aguinaldo
from compromisos c
cross join lateral (
  -- Cada ocurrencia se calcula desde la primera fecha (no sumando un mes a la anterior), así un día 31
  -- vuelve a ser 31 después de febrero
  select case when c.frecuencia = 'unica' then c.fecha_proxima
              else (c.fecha_proxima + k * case c.frecuencia when 'mensual' then interval '1 month'
                                                            when 'bimestral' then interval '2 months'
                                                            when 'trimestral' then interval '3 months'
                                                            when 'semestral' then interval '6 months'
                                                            else interval '1 year' end)::date end as fecha
  from generate_series(0, case when c.frecuencia = 'unica' then 0 else 600 end) k
) gs
where c.activo
  and gs.fecha <= case when c.frecuencia = 'unica' then c.fecha_proxima
                       else least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months')::date end
  and not exists (select 1 from compromisos_registrados x
                  where x.compromiso_id = c.id and x.fecha = gs.fecha and not x.aguinaldo)
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
  and not exists (select 1 from compromisos_registrados x
                  where x.compromiso_id = c.id and x.fecha = a.fecha and x.aguinaldo)
  and a.fecha <= least(coalesce(c.fecha_fin, current_date + interval '12 months'), current_date + interval '12 months');
