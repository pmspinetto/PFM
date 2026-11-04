-- =====================================================================
-- Correcciones confirmadas por el usuario (solo cambia si los movimientos siguen como estaban):
-- 1. Una transferencia entre cuentas propias se anotó a mano con un importe equivocado y también llegó
--    por mail con el importe correcto: se borra la salida anotada, la entrada anotada toma el importe del
--    mail y queda vinculada a la salida del mail.
-- 2. Un pago anotado a mano en otra cuenta duplicaba la transferencia avisada por mail: se borra el
--    anotado, el vencimiento que había registrado pasa a apuntar a la transferencia y se quita un registro
--    de ese compromiso con una fecha que no es de ninguna de sus cuotas.
-- =====================================================================

-- 1. Transferencia entre cuentas propias
do $$
begin
  if exists (select 1 from movimientos where id = 270 and origen = 'manual')
     and exists (select 1 from movimientos where id = 271 and origen = 'manual')
     and exists (select 1 from movimientos where id = 272 and origen = 'mail')
     and exists (select 1 from transferencias_internas where mov_salida_id = 272 and mov_entrada_id is null) then
    delete from movimientos where id = 270;
    update movimientos set monto = (select -monto from movimientos where id = 272) where id = 271;
    update transferencias_internas set mov_entrada_id = 271 where mov_salida_id = 272 and mov_entrada_id is null;
  end if;
end $$;

-- 2. Pago duplicado
do $$
begin
  if exists (select 1 from movimientos where id = 269 and origen = 'manual')
     and exists (select 1 from movimientos where id = 245 and origen = 'mail') then
    update compromisos_registrados set movimiento_id = 245 where movimiento_id = 269;
    delete from compromisos_registrados where movimiento_id = 245 and compromiso_id = 23 and fecha = '2026-10-30';
    delete from movimientos where id = 269;
  end if;
end $$;
