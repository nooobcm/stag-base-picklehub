begin;

-- The closing time is 11 PM, so the final bookable hour starts at 10 PM (22).
alter table public.bookings drop constraint if exists bookings_start_hour_check;
alter table public.bookings drop constraint if exists bookings_duration_hours_check;
alter table public.bookings drop constraint if exists bookings_check;
alter table public.bookings
  add constraint bookings_start_hour_check check (start_hour between 6 and 22),
  add constraint bookings_duration_hours_check check (duration_hours between 1 and 17),
  add constraint bookings_check check (start_hour + duration_hours <= 23);

alter table public.booking_hour_slots drop constraint if exists booking_hour_slots_hour_check;
alter table public.booking_hour_slots
  add constraint booking_hour_slots_hour_check check (hour between 6 and 22);

-- Keep existing RPC implementations and permissions, extending their hour bounds.
do $$
declare
  v_definition text;
begin
  v_definition := pg_get_functiondef('public.normalize_booking_selected_hours()'::regprocedure);
  v_definition := replace(v_definition, 'cardinality(v_hours)>16', 'cardinality(v_hours)>17');
  v_definition := replace(v_definition, 'v_hours[cardinality(v_hours)]>21', 'v_hours[cardinality(v_hours)]>22');
  v_definition := replace(v_definition, 'between 6 AM and 10 PM', 'between 6 AM and 11 PM');
  execute v_definition;

  v_definition := pg_get_functiondef('public.create_guest_booking(integer,date,integer[],text,text,text)'::regprocedure);
  v_definition := replace(v_definition, 'cardinality(p_selected_hours)>16', 'cardinality(p_selected_hours)>17');
  v_definition := replace(v_definition, 'v_hours[cardinality(v_hours)]>21', 'v_hours[cardinality(v_hours)]>22');
  v_definition := replace(v_definition, 'between 6 AM and 10 PM', 'between 6 AM and 11 PM');
  execute v_definition;

  v_definition := pg_get_functiondef('public.admin_create_closure(integer,date,integer,integer,text)'::regprocedure);
  v_definition := replace(v_definition, 'p_end_hour>22', 'p_end_hour>23');
  v_definition := replace(v_definition, 'between 6 AM and 10 PM', 'between 6 AM and 11 PM');
  execute v_definition;

  v_definition := pg_get_functiondef('public.get_slot_availability(integer,date)'::regprocedure);
  v_definition := replace(v_definition, 'generate_series(6,21)', 'generate_series(6,22)');
  execute v_definition;

  v_definition := pg_get_functiondef('public.get_unavailable_hours(integer,date)'::regprocedure);
  v_definition := replace(v_definition, 'generate_series(6,21)', 'generate_series(6,22)');
  execute v_definition;
end;
$$;

commit;
