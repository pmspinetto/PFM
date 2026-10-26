-- =====================================================================
-- Patrimonio e inversiones
-- - activos: datos de inversiones (subtipo, institución, moneda, capital, tasa, fechas).
-- - tipos_cambio admite el valor UVA diario (lo carga el script de Gmail desde el BCRA).
-- No modifica datos existentes: agrega columnas, amplía una restricción y reemplaza una función.
-- =====================================================================

alter table activos
  add column if not exists subtipo           text check (subtipo in (
                                               'plazo_fijo','fci','acciones','bonos','cedear','cripto','dolares','otro')),
  add column if not exists institucion_id    bigint references instituciones(id),
  add column if not exists moneda            text check (moneda in ('ARS','USD')),
  add column if not exists capital           numeric(18,2),
  add column if not exists tna               numeric(7,3),
  add column if not exists fecha_inicio      date,
  add column if not exists fecha_vencimiento date;

alter table tipos_cambio drop constraint if exists tipos_cambio_tipo_check;
alter table tipos_cambio add constraint tipos_cambio_tipo_check
  check (tipo in ('oficial','mep','blue','tarjeta','uva'));

create or replace function registrar_tipos_cambio(p jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
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
  return n;
end;
$$;
