-- =====================================================================
-- Permisos: solo los usuarios con sesión iniciada pueden llamar a las funciones que escriben.
-- Las dos ya rechazan a quien no está autorizado (es_autorizado()); esto agrega una segunda barrera.
-- es_autorizado y factor_ipc siguen abiertas porque las usan las políticas y las vistas.
-- No modifica datos.
-- =====================================================================

revoke execute on function borrar_movimiento(bigint) from public, anon;
revoke execute on function guardar_importacion(jsonb) from public, anon;
grant execute on function borrar_movimiento(bigint) to authenticated;
grant execute on function guardar_importacion(jsonb) to authenticated;
