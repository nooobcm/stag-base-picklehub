begin;

alter table public.courts
  add column if not exists floor_type text,
  add column if not exists hourly_rate integer;

update public.courts
set floor_type = case id when 1 then 'Rubberized' when 2 then 'Silica' end,
    hourly_rate = case id when 1 then 250 when 2 then 350 end
where id in (1, 2);

alter table public.courts
  alter column floor_type set not null,
  alter column hourly_rate set not null;

create or replace function public.set_booking_court_price()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_hourly_rate integer;
begin
  select c.hourly_rate
  into v_hourly_rate
  from public.courts c
  where c.id = new.court_id and c.active;

  if v_hourly_rate is null then
    raise exception 'This court is unavailable';
  end if;

  new.total_price := v_hourly_rate * new.duration_hours;
  return new;
end;
$$;

drop trigger if exists set_booking_court_price on public.bookings;
create trigger set_booking_court_price
before insert or update of court_id, duration_hours
on public.bookings
for each row execute function public.set_booking_court_price();

commit;
