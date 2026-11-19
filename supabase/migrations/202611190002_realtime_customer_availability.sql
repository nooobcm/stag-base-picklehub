begin;

-- Keep the Realtime payload limited to court/date signals. Booking rows contain
-- customer contact details and must not be exposed to anonymous subscribers.
create table if not exists public.availability_signals (
  court_id integer not null references public.courts(id) on delete cascade,
  booking_date date not null,
  updated_at timestamptz not null default now(),
  primary key (court_id, booking_date)
);

alter table public.availability_signals enable row level security;

drop policy if exists "Anyone can read availability signals" on public.availability_signals;
create policy "Anyone can read availability signals"
  on public.availability_signals
  for select
  to anon, authenticated
  using (true);

grant select on public.availability_signals to anon, authenticated;
grant insert, update on public.availability_signals to service_role;

create or replace function public.bump_availability_signal(
  p_fallback_court_id integer,
  p_booking_date date,
  p_court_selections jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selection jsonb;
  v_court_id integer;
  v_found_court boolean := false;
begin
  if jsonb_typeof(p_court_selections) = 'array' then
    for v_selection in select value from jsonb_array_elements(p_court_selections)
    loop
      if coalesce(v_selection->>'court_id', '') ~ '^[0-9]+$' then
        v_court_id := (v_selection->>'court_id')::integer;
        if v_court_id in (1, 2) then
          insert into public.availability_signals(court_id, booking_date, updated_at)
          values (v_court_id, p_booking_date, clock_timestamp())
          on conflict (court_id, booking_date)
          do update set updated_at = excluded.updated_at;
          v_found_court := true;
        end if;
      end if;
    end loop;
  end if;

  if not v_found_court and p_fallback_court_id in (1, 2) then
    insert into public.availability_signals(court_id, booking_date, updated_at)
    values (p_fallback_court_id, p_booking_date, clock_timestamp())
    on conflict (court_id, booking_date)
    do update set updated_at = excluded.updated_at;
  end if;
end;
$$;

revoke all on function public.bump_availability_signal(integer, date, jsonb) from public, anon, authenticated;

create or replace function public.signal_booking_availability_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.bump_availability_signal(old.court_id, old.booking_date, old.court_selections);
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    perform public.bump_availability_signal(new.court_id, new.booking_date, new.court_selections);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.signal_booking_availability_change() from public, anon, authenticated;

drop trigger if exists bookings_signal_availability_change on public.bookings;
create trigger bookings_signal_availability_change
  after insert or update or delete on public.bookings
  for each row execute function public.signal_booking_availability_change();

create or replace function public.signal_closure_availability_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court_id integer;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
  v_date date;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_court_id := old.court_id;
    v_starts_at := old.starts_at;
    v_ends_at := old.ends_at;
    for v_date in
      select generate_series(
        (v_starts_at at time zone 'Asia/Manila')::date,
        (v_ends_at at time zone 'Asia/Manila')::date,
        interval '1 day'
      )::date
    loop
      perform public.bump_availability_signal(v_court_id, v_date, '[]'::jsonb);
    end loop;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_court_id := new.court_id;
    v_starts_at := new.starts_at;
    v_ends_at := new.ends_at;
    for v_date in
      select generate_series(
        (v_starts_at at time zone 'Asia/Manila')::date,
        (v_ends_at at time zone 'Asia/Manila')::date,
        interval '1 day'
      )::date
    loop
      perform public.bump_availability_signal(v_court_id, v_date, '[]'::jsonb);
    end loop;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.signal_closure_availability_change() from public, anon, authenticated;

drop trigger if exists court_closures_signal_availability_change on public.court_closures;
create trigger court_closures_signal_availability_change
  after insert or update or delete on public.court_closures
  for each row execute function public.signal_closure_availability_change();

do $$
begin
  alter publication supabase_realtime add table public.availability_signals;
exception
  when duplicate_object then null;
end;
$$;

commit;
