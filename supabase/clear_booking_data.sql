-- Permanently clears customer bookings and their payment/audit rows.
-- Run from the Supabase SQL Editor as the project owner.
-- Customer accounts, courts, maintenance closures, and app settings are preserved.
begin;

delete from public.payments;
delete from public.bookings;
delete from public.audit_logs where entity_type in ('booking','payment');

commit;
