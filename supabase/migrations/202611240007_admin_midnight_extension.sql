begin;

-- Extend the slot table by one hour for administrator-managed booking edits.
-- Customer booking RPCs continue to cap selections at hour 22 (10 PM–11 PM).
alter table public.bookings drop constraint if exists bookings_start_hour_check;
alter table public.bookings
  add constraint bookings_start_hour_check check (start_hour between 6 and 23);

alter table public.booking_hour_slots drop constraint if exists booking_hour_slots_hour_check;
alter table public.booking_hour_slots
  add constraint booking_hour_slots_hour_check check (hour between 6 and 23);

-- The normalization trigger accepts hour 23 only for authenticated admins.
do $$
declare
  v_definition text;
  v_original text;
begin
  v_definition := pg_get_functiondef('public.normalize_booking_selected_hours()'::regprocedure);
  v_original := v_definition;
  v_definition := replace(v_definition, 'cardinality(v_hours)>17', 'cardinality(v_hours)>18');
  v_definition := replace(v_definition, 'v_hours[cardinality(v_hours)]>22', 'v_hours[cardinality(v_hours)]>23');
  v_definition := replace(
    v_definition,
    '  new.selected_hours:=v_hours;',
    E'  if v_hours[cardinality(v_hours)]>22 and not public.is_admin() then\n    raise exception ''The midnight extension is available to administrators only'';\n  end if;\n\n  new.selected_hours:=v_hours;'
  );
  if v_definition = v_original
     or position('cardinality(v_hours)>18' in v_definition) = 0
     or position('midnight extension is available to administrators only' in v_definition) = 0 then
    raise exception 'Could not safely update booking hour normalization for admin midnight extension';
  end if;
  execute v_definition;
end;
$$;

-- Both adjustment RPC signatures are retained for compatibility. Only admins
-- can call either one, and they may now select hour 23 (11 PM–midnight).
do $$
declare
  v_signature regprocedure;
  v_definition text;
  v_original text;
begin
  foreach v_signature in array array[
    'public.admin_adjust_booking_time(uuid,jsonb)'::regprocedure,
    'public.admin_adjust_booking_time(uuid,jsonb,date)'::regprocedure
  ] loop
    v_definition := pg_get_functiondef(v_signature);
    v_original := v_definition;
    v_definition := replace(v_definition, 'cardinality(v_selection.hours) not between 1 and 17', 'cardinality(v_selection.hours) not between 1 and 18');
    v_definition := replace(v_definition, 'v_selection.hours[cardinality(v_selection.hours)] > 22', 'v_selection.hours[cardinality(v_selection.hours)] > 23');
    v_definition := replace(v_definition, 'Choose valid court hours between 6 AM and 11 PM', 'Choose valid court hours between 6 AM and midnight');
    if v_definition = v_original
       or position('cardinality(v_selection.hours) not between 1 and 18' in v_definition) = 0
       or position('v_selection.hours[cardinality(v_selection.hours)] > 23' in v_definition) = 0 then
      raise exception 'Could not safely update % for admin midnight extension', v_signature;
    end if;
    execute v_definition;
  end loop;
end;
$$;

-- Keep the extra hour out of the customer availability RPC entirely. The admin
-- picker uses this separately permissioned function to check its final slot.
create or replace function public.admin_get_slot_availability(
  p_court_id integer,
  p_booking_date date
)
returns table(hour integer, slot_status text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  perform public.expire_booking_holds();

  return query
  with occupied as (
    select s.hour::integer as hour,
      case when b.status = 'held' then 'held'
           when b.status = 'pending' then 'pending'
           else 'booked' end as slot_status
    from public.booking_hour_slots s
    join public.bookings b on b.id = s.booking_id
    where s.court_id = p_court_id
      and s.booking_date = p_booking_date
      and b.status in ('held', 'pending', 'confirmed', 'completed')
  ), maintenance as (
    select distinct h::integer as hour, 'maintenance'::text as slot_status
    from public.court_closures c
    cross join lateral generate_series(6, 23) h
    where c.court_id = p_court_id
      and (p_booking_date::timestamp + make_interval(hours => h + 1)) at time zone 'Asia/Manila' > c.starts_at
      and (p_booking_date::timestamp + make_interval(hours => h)) at time zone 'Asia/Manila' < c.ends_at
  )
  select * from occupied
  union
  select * from maintenance;
end;
$$;

revoke all on function public.admin_get_slot_availability(integer,date) from public,anon;
grant execute on function public.admin_get_slot_availability(integer,date) to authenticated;

commit;
