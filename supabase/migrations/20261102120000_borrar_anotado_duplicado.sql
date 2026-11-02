-- =====================================================================
-- Borra un ingreso anotado a mano que duplicaba uno ya importado del resumen de la misma cuenta
-- (mismo importe, un día de diferencia). Confirmado por el usuario.
-- Solo borra si sigue siendo ese movimiento anotado a mano y existe el del resumen.
-- =====================================================================

delete from movimientos m
where m.id = 235 and m.origen = 'manual' and m.id_externo like 'manual:%'
  and exists (select 1 from movimientos r
              where r.cuenta_id = m.cuenta_id and r.origen = 'resumen' and r.moneda = m.moneda
                and r.monto = m.monto and abs(r.fecha - m.fecha) <= 5);
