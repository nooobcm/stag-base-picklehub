begin;

-- Add date changes to the existing administrator adjustment RPC while keeping
-- the original two argument function (including its in-progress extension rules)
-- available to older clients.
do $$
declare
  v_definition text;
  v_updated text;
begin
  v_definition := pg_get_functiondef('public.admin_adjust_booking_time(uuid,jsonb)'::regprocedure);
  v_updated := replace(
    v_definition,
    'admin_adjust_booking_time(p_booking_id uuid, p_court_selections jsonb)',
    'admin_adjust_booking_time(p_booking_id uuid, p_court_selections jsonb, p_booking_date date)'
  );
  v_updated := replace(v_updated, '  v_requested_end smallint;', E'  v_requested_end smallint;\n  v_target_date date;');

  v_updated := replace(
    v_updated,
    $old_guard$  select exists (
    select 1 from public.booking_hour_slots s
    where s.booking_id=b.id
      and (b.booking_date::timestamp + make_interval(hours=>s.hour)) at time zone 'Asia/Manila' <= now()
  ) into v_play_started;

  if v_play_started and not exists (
    select 1 from public.booking_hour_slots s
    where s.booking_id=b.id
      and (b.booking_date::timestamp + make_interval(hours=>s.hour)) at time zone 'Asia/Manila' <= now()
      and (b.booking_date::timestamp + make_interval(hours=>s.hour+1)) at time zone 'Asia/Manila' > now()
  ) then
    raise exception 'A booking can only be extended while play is in progress';
  end if;$old_guard$,
    $new_guard$  v_target_date := coalesce(p_booking_date,b.booking_date);
  if v_target_date < (now() at time zone 'Asia/Manila')::date then
    raise exception 'Choose today or a future booking date';
  end if;

  if v_target_date=b.booking_date then
    select exists (
      select 1 from public.booking_hour_slots s
      where s.booking_id=b.id
        and (b.booking_date::timestamp + make_interval(hours=>s.hour)) at time zone 'Asia/Manila' <= now()
    ) into v_play_started;

    if v_play_started and not exists (
      select 1 from public.booking_hour_slots s
      where s.booking_id=b.id
        and (b.booking_date::timestamp + make_interval(hours=>s.hour)) at time zone 'Asia/Manila' <= now()
        and (b.booking_date::timestamp + make_interval(hours=>s.hour+1)) at time zone 'Asia/Manila' > now()
    ) then
      raise exception 'A booking can only be extended while play is in progress';
    end if;
  else
    v_play_started := false;
  end if;$new_guard$
  );

  v_updated := replace(
    v_updated,
    E'    if exists (\n      select 1 from unnest(v_selection.hours) as slots(hour)\n      join public.booking_hour_slots s',
    E'    if v_target_date<>b.booking_date and exists (\n      select 1 from unnest(v_selection.hours) as slots(hour)\n      where (v_target_date::timestamp+make_interval(hours=>slots.hour)) at time zone ''Asia/Manila'' <= now()\n    ) then\n      raise exception ''Choose future booking hours'';\n    end if;\n\n    if exists (\n      select 1 from unnest(v_selection.hours) as slots(hour)\n      join public.booking_hour_slots s'
  );
  v_updated := replace(v_updated, 's.booking_date=b.booking_date', 's.booking_date=v_target_date');
  v_updated := replace(v_updated, '(b.booking_date::timestamp+make_interval(hours=>slots.hour))', '(v_target_date::timestamp+make_interval(hours=>slots.hour))');
  v_updated := replace(v_updated, '(b.booking_date::timestamp+make_interval(hours=>slots.hour+1))', '(v_target_date::timestamp+make_interval(hours=>slots.hour+1))');
  v_updated := replace(v_updated, 'b.id,(item->>''court_id'')::integer,b.booking_date,hour_text.value::smallint', 'b.id,(item->>''court_id'')::integer,v_target_date,hour_text.value::smallint');
  v_updated := replace(v_updated, '  set court_id=v_primary_court,', E'  set booking_date=v_target_date,\n      court_id=v_primary_court,');
  v_updated := replace(v_updated, '    ''old_total'',b.total_price,', E'    ''old_booking_date'',b.booking_date,\n    ''new_booking_date'',v_target_date,\n    ''old_total'',b.total_price,');

  if v_updated = v_definition
     or position('p_booking_date date' in v_updated) = 0
     or position('v_target_date date' in v_updated) = 0
     or position('s.booking_date=v_target_date' in v_updated) = 0
     or position('Choose future booking hours' in v_updated) = 0 then
    raise exception 'Could not safely add booking date rescheduling to admin_adjust_booking_time';
  end if;

  execute v_updated;
end;
$$;

revoke all on function public.admin_adjust_booking_time(uuid,jsonb,date) from public,anon;
grant execute on function public.admin_adjust_booking_time(uuid,jsonb,date) to authenticated;

commit;
