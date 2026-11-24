begin;

-- The first paddle migration was already recorded in some environments
-- before this read-only stock endpoint was added. A follow-up migration makes
-- the endpoint available without rewriting applied migration history.
create or replace function public.get_paddle_availability(p_booking_date date)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(slot.hour::text,
    greatest(0, 4 - coalesce(used.paddle_count, 0))), '{}'::jsonb)
  from generate_series(6, 22) as slot(hour)
  left join lateral (
    select sum(b.paddle_count)::integer as paddle_count
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.booking_date = p_booking_date
      and s.hour = slot.hour
      and (
        b.status = 'confirmed'
        or (b.status = 'pending'
          and coalesce(b.hold_expires_at, now() + interval '1 day') > now())
      )
  ) used on true;
$$;

revoke all on function public.get_paddle_availability(date) from public;
grant execute on function public.get_paddle_availability(date) to anon, authenticated;

commit;
