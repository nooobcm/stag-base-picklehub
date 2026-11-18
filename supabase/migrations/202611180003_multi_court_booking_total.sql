begin;

create or replace function public.set_booking_court_price()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_hourly_rate integer;
  v_total_price integer;
begin
  select c.hourly_rate
    into v_hourly_rate
  from public.courts c
  where c.id = new.court_id and c.active;

  if v_hourly_rate is null then
    raise exception 'This court is unavailable';
  end if;

  if jsonb_typeof(new.court_selections) = 'array'
     and jsonb_array_length(new.court_selections) > 0 then
    select sum(c.hourly_rate * jsonb_array_length(selection.value->'hours'))::integer
      into v_total_price
    from jsonb_array_elements(new.court_selections) as selection(value)
    join public.courts c
      on c.id = (selection.value->>'court_id')::integer
     and c.active;

    if v_total_price is null or v_total_price <= 0 then
      raise exception 'Could not calculate the selected court total';
    end if;

    new.total_price := v_total_price;
  else
    new.total_price := v_hourly_rate * new.duration_hours;
  end if;

  return new;
end;
$$;

commit;
