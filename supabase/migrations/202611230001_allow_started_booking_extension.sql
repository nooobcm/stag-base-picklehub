begin;

-- Keep an in-progress booking's existing hours fixed, but let admins append
-- consecutive available hours to its end.
do $$
declare
  v_definition text;
  v_updated text;
begin
  v_definition := pg_get_functiondef('public.admin_adjust_booking_time(uuid,jsonb)'::regprocedure);
  v_updated := replace(
    v_definition,
    '  v_court_count integer;',
    E'  v_court_count integer;\n  v_play_started boolean := false;\n  v_original_end smallint;\n  v_requested_end smallint;'
  );

  v_updated := replace(
    v_updated,
    $old_guard$  if exists (
    select 1 from public.booking_hour_slots s
    where s.booking_id=b.id
      and (b.booking_date::timestamp + make_interval(hours=>s.hour)) at time zone 'Asia/Manila' <= now()
  ) then
    raise exception 'A booking time cannot be adjusted after play has started';
  end if;$old_guard$,
    $new_guard$  select exists (
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
  end if;$new_guard$
  );

  v_updated := replace(
    v_updated,
    E'    if exists (\n      select 1 from unnest(v_selection.hours) as slots(hour)\n      join public.booking_hour_slots s',
    E'    if v_play_started then\n      if exists (\n        select 1 from public.booking_hour_slots original_slot\n        where original_slot.booking_id=b.id\n          and original_slot.court_id=v_selection.court_id\n          and not (original_slot.hour = any(v_selection.hours))\n      ) then\n        raise exception ''Once play has started, existing booked hours cannot be removed'';\n      end if;\n\n      select max(hour) into v_original_end\n      from public.booking_hour_slots\n      where booking_id=b.id and court_id=v_selection.court_id;\n      select max(hour) into v_requested_end from unnest(v_selection.hours) as requested(hour);\n\n      if exists (\n        select 1 from unnest(v_selection.hours) as requested(hour)\n        where requested.hour <= v_original_end\n          and not exists (\n            select 1 from public.booking_hour_slots original_slot\n            where original_slot.booking_id=b.id\n              and original_slot.court_id=v_selection.court_id\n              and original_slot.hour=requested.hour\n          )\n      ) or exists (\n        select 1 from generate_series(v_original_end+1,v_requested_end) as extension(hour)\n        where not (extension.hour = any(v_selection.hours))\n      ) then\n        raise exception ''After play starts, only consecutive hours at the end of this booking can be added'';\n      end if;\n    end if;\n\n    if exists (\n      select 1 from unnest(v_selection.hours) as slots(hour)\n      join public.booking_hour_slots s'
  );

  if v_updated = v_definition
     or position('v_play_started boolean' in v_updated) = 0
     or position('Once play has started, existing booked hours cannot be removed' in v_updated) = 0 then
    raise exception 'Could not safely update admin_adjust_booking_time for in-progress extensions';
  end if;

  execute v_updated;
end;
$$;

commit;
