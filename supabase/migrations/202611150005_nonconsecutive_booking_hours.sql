begin;

alter table public.bookings
  add column if not exists selected_hours smallint[];

update public.bookings b
set selected_hours = array(
  select h::smallint
  from generate_series(b.start_hour,b.start_hour+b.duration_hours-1) h
  order by h
)
where selected_hours is null;

alter table public.bookings
  alter column selected_hours set not null;

alter table public.bookings drop constraint if exists bookings_no_overlap;

create table if not exists public.booking_hour_slots (
  booking_id uuid not null references public.bookings(id) on delete cascade,
  court_id integer not null references public.courts(id),
  booking_date date not null,
  hour smallint not null check(hour between 6 and 21),
  primary key (booking_id,hour)
);

create unique index if not exists booking_hour_slots_unique_active_idx
  on public.booking_hour_slots(court_id,booking_date,hour);

insert into public.booking_hour_slots(booking_id,court_id,booking_date,hour)
select b.id,b.court_id,b.booking_date,h::smallint
from public.bookings b
cross join lateral unnest(b.selected_hours) h
where b.status in ('held','pending','confirmed','completed')
on conflict do nothing;

alter table public.booking_hour_slots enable row level security;
revoke all on public.booking_hour_slots from public,anon,authenticated;

create or replace function public.normalize_booking_selected_hours()
returns trigger language plpgsql set search_path = '' as $$
declare v_hours smallint[];
begin
  if new.selected_hours is null then
    select array_agg(h::smallint order by h)
      into v_hours
    from generate_series(new.start_hour,new.start_hour+new.duration_hours-1) h;
  else
    select array_agg(h order by h)
      into v_hours
    from (select distinct x::smallint as h from unnest(new.selected_hours) x) normalized;
  end if;

  if coalesce(cardinality(v_hours),0)<1 or cardinality(v_hours)>16
    or array_position(v_hours,null) is not null
    or v_hours[1]<6 or v_hours[cardinality(v_hours)]>21 then
    raise exception 'Choose one or more hours between 6 AM and 10 PM';
  end if;

  new.selected_hours:=v_hours;
  new.start_hour:=v_hours[1];
  new.duration_hours:=cardinality(v_hours);
  return new;
end;
$$;

drop trigger if exists bookings_normalize_selected_hours on public.bookings;
create trigger bookings_normalize_selected_hours
before insert on public.bookings
for each row execute function public.normalize_booking_selected_hours();

create or replace function public.reserve_booking_hour_slots()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('held','pending','confirmed','completed') then
    insert into public.booking_hour_slots(booking_id,court_id,booking_date,hour)
    select new.id,new.court_id,new.booking_date,h
    from unnest(new.selected_hours) h;
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_reserve_hour_slots on public.bookings;
create trigger bookings_reserve_hour_slots
after insert on public.bookings
for each row execute function public.reserve_booking_hour_slots();

create or replace function public.release_booking_hour_slots()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('held','pending','confirmed','completed')
    and new.status not in ('held','pending','confirmed','completed') then
    delete from public.booking_hour_slots where booking_id=new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_release_hour_slots on public.bookings;
create trigger bookings_release_hour_slots
after update of status on public.bookings
for each row execute function public.release_booking_hour_slots();

create or replace function public.get_unavailable_hours(
  p_court_id integer,
  p_booking_date date
)
returns table(hour integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  return query
  select s.hour::integer
  from public.booking_hour_slots s
  where s.court_id=p_court_id and s.booking_date=p_booking_date
  union
  select distinct h::integer
  from public.court_closures c
  cross join lateral generate_series(6,21) h
  where c.court_id=p_court_id
    and (p_booking_date::timestamp+make_interval(hours=>h+1)) at time zone 'Asia/Manila'>c.starts_at
    and (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<c.ends_at
  union
  select h::integer
  from generate_series(6,21) h
  where p_booking_date=(now() at time zone 'Asia/Manila')::date
    and (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<=now();
end;
$$;

revoke all on function public.get_unavailable_hours(integer,date) from public,anon;
grant execute on function public.get_unavailable_hours(integer,date) to anon,authenticated;

drop function if exists public.create_guest_booking(integer,date,integer,integer,text,text,text);

create or replace function public.create_guest_booking(
  p_court_id integer,
  p_booking_date date,
  p_selected_hours integer[],
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_booking public.bookings;
  v_token text:=encode(extensions.gen_random_bytes(32),'hex');
  v_hours smallint[];
  v_hold_minutes integer;
  v_name text:=nullif(trim(p_customer_name),'');
  v_email text:=lower(nullif(trim(p_customer_email),''));
  v_phone text:=nullif(trim(p_customer_phone),'');
begin
  if v_name is null or length(v_name)>120 then raise exception 'Enter your name'; end if;
  if v_email is null or length(v_email)>254 or v_email !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then raise exception 'Enter a valid email address'; end if;
  if v_phone is null or length(v_phone)>32 or v_phone !~ '^[+0-9() .-]{7,32}$' then raise exception 'Enter a valid phone number'; end if;
  if p_court_id not in (1,2) or p_selected_hours is null or cardinality(p_selected_hours)<1 or cardinality(p_selected_hours)>16 then raise exception 'Select one or more available hours'; end if;

  select array_agg(h order by h) into v_hours
  from (select distinct x::smallint as h from unnest(p_selected_hours) x) selected;

  if v_hours[1] is null or v_hours[cardinality(v_hours)] is null or array_position(v_hours,null) is not null
    or v_hours[1]<6 or v_hours[cardinality(v_hours)]>21 then raise exception 'Choose hours between 6 AM and 10 PM'; end if;
  if p_booking_date<(now() at time zone 'Asia/Manila')::date then raise exception 'Choose a future date'; end if;
  if exists(select 1 from unnest(v_hours) h where (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<=now()) then raise exception 'One or more selected hours have already passed'; end if;

  perform public.expire_booking_holds();
  perform pg_advisory_xact_lock(6001,p_court_id);

  select coalesce((value->>'hold_minutes')::integer,10) into v_hold_minutes
  from public.app_settings where key='booking_policy';

  if exists(
    select 1 from public.court_closures c
    cross join lateral unnest(v_hours) h
    where c.court_id=p_court_id
      and tstzrange(c.starts_at,c.ends_at,'[)') && tstzrange(
        (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila',
        (p_booking_date::timestamp+make_interval(hours=>h+1)) at time zone 'Asia/Manila','[)')
  ) then raise exception 'This court is closed during one or more selected hours'; end if;

  insert into public.bookings(
    user_id,court_id,booking_date,start_hour,duration_hours,selected_hours,
    total_price,status,payment_status,hold_expires_at,customer_name,customer_email,
    customer_phone,guest_access_token_hash
  ) values(
    null,p_court_id,p_booking_date,v_hours[1],cardinality(v_hours),v_hours,
    cardinality(v_hours)*(select c.hourly_rate from public.courts c where c.id=p_court_id and c.active),
    'held','unpaid',now()+make_interval(mins=>coalesce(v_hold_minutes,10)),
    v_name,v_email,v_phone,encode(extensions.digest(v_token,'sha256'),'hex')
  ) returning * into v_booking;

  return jsonb_build_object(
    'id',v_booking.id,'reference',v_booking.reference,'total_price',v_booking.total_price,
    'hold_expires_at',v_booking.hold_expires_at,'access_token',v_token
  );
exception when unique_violation then
  raise exception 'One or more selected hours were just taken. Choose another time.';
end;
$$;

revoke all on function public.create_guest_booking(integer,date,integer[],text,text,text) from public,authenticated;
grant execute on function public.create_guest_booking(integer,date,integer[],text,text,text) to anon;

create or replace function public.admin_create_closure(
  p_court_id integer,p_date date,p_start_hour integer,p_end_hour integer,p_reason text
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_start timestamptz; v_end timestamptz; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_court_id not in (1,2) or p_start_hour<6 or p_end_hour>22 or p_end_hour<=p_start_hour or nullif(trim(p_reason),'') is null then
    raise exception 'Enter a valid court closure between 6 AM and 10 PM with a reason';
  end if;
  if p_date<(now() at time zone 'Asia/Manila')::date then raise exception 'Choose today or a future date'; end if;
  perform public.expire_booking_holds();
  perform pg_advisory_xact_lock(6001,p_court_id);
  v_start:=(p_date::timestamp+make_interval(hours=>p_start_hour)) at time zone 'Asia/Manila';
  v_end:=(p_date::timestamp+make_interval(hours=>p_end_hour)) at time zone 'Asia/Manila';
  if exists(
    select 1 from public.booking_hour_slots s
    join public.bookings b on b.id=s.booking_id
    where s.court_id=p_court_id and s.booking_date=p_date
      and s.hour>=p_start_hour and s.hour<p_end_hour
      and b.status in ('held','pending','confirmed','completed')
  ) then raise exception 'An existing booking overlaps this closure. Cancel or reschedule it first.'; end if;
  insert into public.court_closures(court_id,starts_at,ends_at,reason,created_by)
  values(p_court_id,v_start,v_end,trim(p_reason),auth.uid()) returning id into v_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'court_closed','closure',v_id,jsonb_build_object('court_id',p_court_id,'reason',p_reason));
  return v_id;
end;
$$;

commit;
