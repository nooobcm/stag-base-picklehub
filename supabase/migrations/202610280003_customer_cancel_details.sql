-- Let customers see only their own customer-cancellation audit records.
grant select on public.audit_logs to authenticated;

create policy "Owners read own booking cancellation audit"
on public.audit_logs for select to authenticated
using (
  action = 'customer_booking_cancelled'
  and entity_type = 'booking'
  and exists (
    select 1
    from public.bookings b
    where b.id = entity_id
      and b.user_id = (select auth.uid())
  )
);
