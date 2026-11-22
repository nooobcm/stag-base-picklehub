begin;

create or replace function public.admin_adjust_booking_time(
  p_booking_id uuid,
  p_court_selections jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  v_selection record;
  v_new_selections jsonb := '[]'::jsonb;
  v_primary_court integer;
  v_primary_hours smallint[];
  v_rate integer;
  v_total integer := 0;
  v_received numeric(12,2) := 0;
  v_court_count integer;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_court_selections is null or jsonb_typeof(p_court_selections) <> 'array'
     or jsonb_array_length(p_court_selections) not between 1 and 2 then
    raise exception 'Choose a valid time for each court in this booking';
  end if;

  perform public.expire_booking_holds();
  perform pg_advisory_xact_lock(6001, 1);
  perform pg_advisory_xact_lock(6001, 2);

  select * into b from public.bookings where id = p_booking_id for update;
  if b.id is null then raise exception 'Booking not found'; end if;
  if b.status <> 'confirmed' then
    raise exception 'Only confirmed bookings can have their time adjusted';
  end if;
  if exists (
    select 1 from public.booking_hour_slots s
    where s.booking_id=b.id
      and (b.booking_date::timestamp + make_interval(hours=>s.hour)) at time zone 'Asia/Manila' <= now()
  ) then
    raise exception 'A booking time cannot be adjusted after play has started';
  end if;

  select count(distinct (item->>'court_id')::integer) into v_court_count
  from jsonb_array_elements(p_court_selections) as payload(item);
  if v_court_count <> jsonb_array_length(p_court_selections) then
    raise exception 'Each court can only be listed once';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_court_selections) as payload(item)
    where jsonb_typeof(item->'hours') is distinct from 'array'
  ) then
    raise exception 'Choose valid hours for every court';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(b.court_selections,'[]'::jsonb)) as old_payload(old_item)
    where not exists (
      select 1 from jsonb_array_elements(p_court_selections) as new_payload(new_item)
      where (new_item->>'court_id')::integer=(old_item->>'court_id')::integer
    )
  ) or v_court_count <> jsonb_array_length(coalesce(b.court_selections,'[]'::jsonb)) then
    raise exception 'Adjust the existing court times without adding or removing a court';
  end if;

  for v_selection in
    select item as selection,
      (item->>'court_id')::integer as court_id,
      array(select distinct hour_text.value::smallint
        from jsonb_array_elements_text(item->'hours') hour_text(value)
        order by 1) as hours
    from jsonb_array_elements(p_court_selections) as payload(item)
    order by (item->>'court_id')::integer
  loop
    if v_selection.court_id not in (1,2)
       or jsonb_typeof(v_selection.selection->'hours') is distinct from 'array'
       or cardinality(v_selection.hours) not between 1 and 17
       or array_position(v_selection.hours,null) is not null
       or v_selection.hours[1] < 6 or v_selection.hours[cardinality(v_selection.hours)] > 22 then
      raise exception 'Choose valid court hours between 6 AM and 11 PM';
    end if;

    if exists (
      select 1 from unnest(v_selection.hours) as slots(hour)
      join public.booking_hour_slots s
        on s.court_id=v_selection.court_id and s.booking_date=b.booking_date
       and s.hour=slots.hour and s.booking_id<>b.id
    ) then
      raise exception 'One or more requested hours are already booked';
    end if;
    if exists (
      select 1 from unnest(v_selection.hours) as slots(hour)
      join public.court_closures c on c.court_id=v_selection.court_id
      where tstzrange(c.starts_at,c.ends_at,'[)') && tstzrange(
        (b.booking_date::timestamp+make_interval(hours=>slots.hour)) at time zone 'Asia/Manila',
        (b.booking_date::timestamp+make_interval(hours=>slots.hour+1)) at time zone 'Asia/Manila','[)')
    ) then
      raise exception 'The requested time overlaps a court closure';
    end if;

    select c.hourly_rate into v_rate from public.courts c where c.id=v_selection.court_id and c.active;
    select coalesce((
      select (item->>'hourly_rate')::integer
      from jsonb_array_elements(coalesce(b.court_selections,'[]'::jsonb)) as old_payload(item)
      where (item->>'court_id')::integer=v_selection.court_id
    ),v_rate) into v_rate;
    if v_rate is null or v_rate<1 then raise exception 'Could not determine the hourly rate for this court'; end if;

    v_total := v_total + cardinality(v_selection.hours)*v_rate;
    v_new_selections := v_new_selections || jsonb_build_array(jsonb_build_object(
      'court_id',v_selection.court_id,
      'hours',to_jsonb(v_selection.hours),
      'hourly_rate',v_rate,
      'subtotal',cardinality(v_selection.hours)*v_rate
    ));
    if v_primary_court is null then
      v_primary_court := v_selection.court_id;
      v_primary_hours := v_selection.hours;
    end if;
  end loop;

  select coalesce(sum(amount),0) into v_received
  from public.booking_payment_transactions where booking_id=b.id;
  if v_total < v_received then
    raise exception 'The new booking total cannot be less than payments already received';
  end if;

  delete from public.booking_hour_slots where booking_id=b.id;
  insert into public.booking_hour_slots(booking_id,court_id,booking_date,hour)
  select b.id,(item->>'court_id')::integer,b.booking_date,hour_text.value::smallint
  from jsonb_array_elements(v_new_selections) as new_payload(item)
  cross join lateral jsonb_array_elements_text(item->'hours') hour_text(value);

  update public.bookings
  set court_id=v_primary_court,
      start_hour=v_primary_hours[1],
      duration_hours=cardinality(v_primary_hours),
      selected_hours=v_primary_hours,
      court_selections=v_new_selections,
      total_price=v_total,
      payment_status=case when v_received=0 then 'unpaid'
        when v_received>=v_total then 'fully_paid' else 'partially_paid' end,
      updated_at=now()
  where id=b.id;

  -- The legacy pricing trigger derives a single-court price from duration.
  -- Restore the recalculated multi-court total after that trigger has run.
  update public.bookings set total_price=v_total where id=b.id;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'booking_time_adjusted','booking',b.id,jsonb_build_object(
    'old_court_selections',b.court_selections,
    'new_court_selections',v_new_selections,
    'old_total',b.total_price,
    'new_total',v_total
  ));

  return jsonb_build_object('total_price',v_total,'court_selections',v_new_selections);
end;
$$;

revoke all on function public.admin_adjust_booking_time(uuid,jsonb) from public,anon;
grant execute on function public.admin_adjust_booking_time(uuid,jsonb) to authenticated;

commit;
