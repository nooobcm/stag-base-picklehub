begin;

-- A customer-submitted reservation stays on hold until the admin approves it.
-- Only an admin-confirmed booking is shown as booked in the court timeline.
create or replace function public.get_slot_availability(
  p_court_id integer,
  p_booking_date date
)
returns table(hour integer, slot_status text)
language sql
stable
security definer
set search_path = ''
as $$
  with occupied as (
    select s.hour::integer as hour,
      case when b.status in ('held','pending') then 'pending' else 'booked' end as slot_status
    from public.booking_hour_slots s
    join public.bookings b on b.id=s.booking_id
    where s.court_id=p_court_id
      and s.booking_date=p_booking_date
      and b.status in ('held','pending','confirmed','completed')
  ), maintenance as (
    select distinct h::integer as hour, 'maintenance'::text as slot_status
    from public.court_closures c
    cross join lateral generate_series(6,22) h
    where c.court_id=p_court_id
      and (p_booking_date::timestamp+make_interval(hours=>h+1)) at time zone 'Asia/Manila'>c.starts_at
      and (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<c.ends_at
  )
  select * from occupied
  union
  select * from maintenance;
$$;

revoke all on function public.get_slot_availability(integer,date) from public;
grant execute on function public.get_slot_availability(integer,date) to anon,authenticated;

commit;
