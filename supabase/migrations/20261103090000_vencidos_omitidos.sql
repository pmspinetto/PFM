-- =====================================================================
-- Vencidos pendientes: Lo que viene muestra los vencimientos de v_flujo_proyectado con fecha
-- anterior a hoy que no se registraron, hasta que se registren o se marquen como omitidos.
-- compromisos_registrados.omitido = true: ese vencimiento no se cobró ni se pagó y no se va a
-- registrar (se saltea); igual que un registrado, v_flujo_proyectado deja de mostrarlo.
-- Agrega una columna; no modifica datos existentes.
-- =====================================================================

alter table compromisos_registrados add column if not exists omitido boolean not null default false;
