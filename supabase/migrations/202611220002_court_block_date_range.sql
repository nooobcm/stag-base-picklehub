begin;

create or replace function public.admin_create_closure_range(
  p_court_id integer,
  p_start_date date,
  p_end_date date,
  p_start_hour integer,
  p_end_hour integer,
  p_reason text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
  v_start timestamptz;
  v_end timestamptz;
  v_id uuid;
  v_count integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  if p_court_id not in (1, 2)
     or p_start_date is null
     or p_end_date is null
     or p_start_date > p_end_date
     or p_start_date < (now() at time zone 'Asia/Manila')::date
     or p_start_hour < 6
     or p_end_hour > 23
     or p_end_hour <= p_start_hour
     or nullif(trim(p_reason), '') is null then
    raise exception 'Enter a valid court, date range, time range, and block reason';
  end if;

  perform public.expire_booking_holds();
  perform pg_advisory_xact_lock(6001, p_court_id);

  if exists (
    select 1
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.court_id = p_court_id
      and s.booking_date between p_start_date and p_end_date
      and s.hour >= p_start_hour
      and s.hour < p_end_hour
      and b.status in ('held', 'pending', 'confirmed', 'completed')
  ) then
    raise exception 'An existing booking overlaps this court block. Cancel or reschedule it first.';
  end if;

  for v_date in
    select generate_series(p_start_date, p_end_date, interval '1 day')::date
  loop
    v_start := (v_date::timestamp + make_interval(hours => p_start_hour)) at time zone 'Asia/Manila';
    v_end := (v_date::timestamp + make_interval(hours => p_end_hour)) at time zone 'Asia/Manila';

    insert into public.court_closures(court_id, starts_at, ends_at, reason, created_by)
    values (p_court_id, v_start, v_end, trim(p_reason), auth.uid())
    returning id into v_id;

    insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
    values (
      auth.uid(),
      'court_closed',
      'closure',
      v_id,
      jsonb_build_object('court_id', p_court_id, 'reason', trim(p_reason), 'date_from', p_start_date, 'date_to', p_end_date)
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.admin_create_closure_range(integer, date, date, integer, integer, text) from public, anon;
grant execute on function public.admin_create_closure_range(integer, date, date, integer, integer, text) to authenticated;

commit;
