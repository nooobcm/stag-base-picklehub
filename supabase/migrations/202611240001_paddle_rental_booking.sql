begin;

alter table public.bookings
  add column paddle_count smallint not null default 0
    check (paddle_count between 0 and 4),
  add column paddle_fee integer not null default 0
    check (paddle_fee >= 0);

-- Expose only remaining paddle counts by hour. Customer names and booking
-- contact details never leave the protected bookings table.
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

-- Keep paddle rentals in the same atomic booking operation as the court
-- reservation. The 4-paddle inventory is checked for every selected hour.
create or replace function public.create_guest_booking_multi(
  p_booking_date date,
  p_court_selections jsonb,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_paddle_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking jsonb;
  v_booking_id uuid;
  v_token text;
  v_rental_hours integer := 0;
  v_paddle_fee integer := 0;
  v_booking_total integer := 0;
begin
  if p_paddle_count is null or p_paddle_count not between 0 and 4 then
    raise exception 'Choose between 0 and 4 paddles';
  end if;

  v_booking := public.create_guest_booking_multi(
    p_booking_date,
    p_court_selections,
    p_customer_name,
    p_customer_email,
    p_customer_phone,
    'online'
  );
  v_booking_id := (v_booking->>'id')::uuid;
  v_token := v_booking->>'access_token';

  if p_paddle_count > 0 then
    -- Serialize paddle inventory checks across bookings on either court.
    perform pg_advisory_xact_lock(6001, 3);

    select count(distinct s.hour)::integer into v_rental_hours
    from public.booking_hour_slots s
    where s.booking_id = v_booking_id;

    if v_rental_hours = 0 then
      raise exception 'Choose booking hours before adding paddle rentals';
    end if;

    if exists (
      select 1
      from public.booking_hour_slots requested
      where requested.booking_id = v_booking_id
        and (
          select coalesce(sum(other_booking.paddle_count), 0)
          from public.booking_hour_slots occupied
          join public.bookings other_booking on other_booking.id = occupied.booking_id
          where occupied.booking_date = requested.booking_date
            and occupied.hour = requested.hour
            and occupied.booking_id <> v_booking_id
            and (
              other_booking.status = 'confirmed'
              or (other_booking.status = 'pending'
                and coalesce(other_booking.hold_expires_at, now() + interval '1 day') > now())
            )
        ) + p_paddle_count > 4
    ) then
      raise exception 'Not enough paddles are available for one or more selected hours';
    end if;

    v_paddle_fee := p_paddle_count * (50 + greatest(v_rental_hours - 1, 0) * 25);
  end if;

  update public.bookings
  set paddle_count = p_paddle_count,
      paddle_fee = v_paddle_fee,
      total_price = total_price + v_paddle_fee,
      updated_at = now()
  where id = v_booking_id
  returning total_price into v_booking_total;

  perform public.confirm_guest_booking_request(v_booking_id, v_token);

  return jsonb_set(
    jsonb_set(
      jsonb_set(v_booking, '{total_price}', to_jsonb(v_booking_total), true),
      '{paddle_count}', to_jsonb(p_paddle_count), true
    ),
    '{paddle_fee}', to_jsonb(v_paddle_fee), true
  );
end;
$$;

revoke all on function public.create_guest_booking_multi(date,jsonb,text,text,text,integer)
  from public, authenticated;
grant execute on function public.create_guest_booking_multi(date,jsonb,text,text,text,integer)
  to anon;

-- Time/date changes should recalculate court fees while retaining the paddle
-- rental fee already attached to the booking.
do $$
declare
  v_function regprocedure;
  v_definition text;
  v_updated text;
begin
  foreach v_function in array array[
    'public.admin_adjust_booking_time(uuid,jsonb)'::regprocedure,
    'public.admin_adjust_booking_time(uuid,jsonb,date)'::regprocedure
  ] loop
    v_definition := pg_get_functiondef(v_function);
    v_updated := replace(v_definition, '  v_total integer := 0;',
      E'  v_total integer := 0;\n  v_rental_hours integer := 0;\n  v_new_paddle_fee integer := 0;');
    v_updated := replace(v_updated, '  select coalesce(sum(amount),0) into v_received',
      E'  select count(distinct hour_text.value::smallint)::integer into v_rental_hours\n  from jsonb_array_elements(v_new_selections) as payload(item)\n  cross join lateral jsonb_array_elements_text(item->''hours'') hour_text(value);\n  v_new_paddle_fee := coalesce(b.paddle_count,0) * (50 + greatest(v_rental_hours - 1,0) * 25);\n\n  select coalesce(sum(amount),0) into v_received');
    v_updated := replace(v_updated, 'v_total < v_received',
      'v_total + v_new_paddle_fee < v_received');
    v_updated := replace(v_updated, 'total_price=v_total',
      'total_price=v_total+v_new_paddle_fee,paddle_fee=v_new_paddle_fee');
    v_updated := replace(v_updated, '''new_total'',v_total',
      '''new_total'',v_total+v_new_paddle_fee');
    v_updated := replace(v_updated, 'jsonb_build_object(''total_price'',v_total,',
      'jsonb_build_object(''total_price'',v_total+v_new_paddle_fee,');

    if v_updated = v_definition
       or position('v_new_paddle_fee integer := 0' in v_updated) = 0
       or position('total_price=v_total+v_new_paddle_fee,paddle_fee=v_new_paddle_fee' in v_updated) = 0 then
      raise exception 'Could not preserve paddle rental fees in %', v_function;
    end if;
    execute v_updated;
  end loop;
end;
$$;

commit;
