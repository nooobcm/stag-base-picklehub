begin;

alter table public.profiles
  add column if not exists is_booking_viewer boolean not null default false;

create or replace function public.is_booking_viewer()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from public.profiles
    where id = (select auth.uid()) and is_booking_viewer and not is_admin
  )
$$;

revoke all on function public.is_booking_viewer() from public, anon;
grant execute on function public.is_booking_viewer() to authenticated;

create or replace function public.get_viewer_daily_bookings(p_booking_date date)
returns table(
  id uuid,
  reference text,
  court_id integer,
  booking_date date,
  start_hour smallint,
  duration_hours smallint,
  selected_hours smallint[],
  court_selections jsonb,
  total_price integer,
  status text,
  customer_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (public.is_admin() or public.is_booking_viewer()) then
    raise exception 'Booking viewer access required';
  end if;

  return query
  select b.id,b.reference,b.court_id,b.booking_date,b.start_hour,b.duration_hours,
         b.selected_hours,b.court_selections,b.total_price,b.status,
         coalesce(nullif(b.customer_name,''),p.full_name,'Customer')
  from public.bookings b
  left join public.profiles p on p.id=b.user_id
  where b.booking_date=p_booking_date
    and b.status in ('held','pending','confirmed','completed')
    and (b.status <> 'held' or b.hold_expires_at is null or b.hold_expires_at > now())
  order by b.court_id,b.start_hour,b.created_at;
end;
$$;

revoke all on function public.get_viewer_daily_bookings(date) from public, anon;
grant execute on function public.get_viewer_daily_bookings(date) to authenticated;

commit;
