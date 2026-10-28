create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, full_name, email)
  values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''), coalesce(new.email,''));
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.create_profile_for_new_user();
revoke all on function public.create_profile_for_new_user() from public, anon, authenticated;

create table public.courts (
  id integer primary key check (id in (1,2)),
  name text not null,
  active boolean not null default true
);
insert into public.courts(id,name) values(1,'The Green'),(2,'The Rally');

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique default upper(substr(encode(gen_random_bytes(5),'hex'),1,8)),
  user_id uuid not null references public.profiles(id),
  court_id integer not null references public.courts(id),
  booking_date date not null,
  start_hour smallint not null check(start_hour between 6 and 21),
  duration_hours smallint not null check(duration_hours between 1 and 16),
  total_price integer not null check(total_price > 0),
  status text not null default 'pending' check(status in ('pending','confirmed','rejected','cancelled','completed')),
  payment_status text not null default 'unpaid' check(payment_status in ('unpaid','proof_submitted','verified','rejected','refunded')),
  hold_expires_at timestamptz not null default (now() + interval '15 minutes'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(start_hour + duration_hours <= 22),
  constraint bookings_no_overlap exclude using gist (
    court_id with =,
    (tstzrange((booking_date::timestamp + make_interval(hours => start_hour)) at time zone 'Asia/Manila',
               (booking_date::timestamp + make_interval(hours => start_hour + duration_hours)) at time zone 'Asia/Manila', '[)')) with &&
  ) where (status in ('pending','confirmed','completed'))
);
create index bookings_user_date_idx on public.bookings(user_id, booking_date desc);
create index bookings_court_date_idx on public.bookings(court_id, booking_date);

create table public.court_closures (
  id uuid primary key default gen_random_uuid(),
  court_id integer not null references public.courts(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check(ends_at > starts_at)
);
create index court_closures_court_time_idx on public.court_closures using gist(court_id, tstzrange(starts_at, ends_at, '[)'));

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id),
  amount integer not null check(amount > 0),
  proof_path text not null,
  status text not null default 'proof_submitted' check(status in ('proof_submitted','verified','rejected')),
  rejection_reason text,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  unique(booking_id, proof_path)
);
create index payments_status_idx on public.payments(status, submitted_at);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
insert into public.app_settings(key,value) values
 ('facility', '{"name":"Stag Base Pickle Hub","city":"Manila","contact":""}'),
 ('payment_instructions', '{"gcash_name":"","gcash_number":"","bank_name":"","bank_account_name":"","bank_account_number":""}'),
 ('booking_policy', '{"hold_minutes":15,"proof_review_hours":24,"cancellation_hours":12,"hourly_rate":250}');

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles where id = (select auth.uid()) and is_admin)
$$;

create or replace function public.get_unavailable_hours(p_court_id integer,p_booking_date date)
returns table(hour integer) language plpgsql stable security definer set search_path = '' as $$
begin
  return query
  select distinct h as hour
  from public.bookings b
  cross join lateral generate_series(b.start_hour::integer,b.start_hour::integer+b.duration_hours::integer-1) h
  where b.court_id=p_court_id and b.booking_date=p_booking_date
    and b.status in ('pending','confirmed','completed')
    and not (b.status='pending' and b.payment_status='unpaid' and b.hold_expires_at<now())
    and not (b.status='pending' and b.payment_status='proof_submitted' and exists(
      select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted' and p.submitted_at < now()-make_interval(hours=>coalesce((select (s.value->>'proof_review_hours')::integer from public.app_settings s where s.key='booking_policy'),24))))
  union
  select distinct h as hour
  from public.court_closures c
  cross join lateral generate_series(6,21) h
  where c.court_id=p_court_id
    and (p_booking_date::timestamp + make_interval(hours => h+1)) at time zone 'Asia/Manila' > c.starts_at
    and (p_booking_date::timestamp + make_interval(hours => h)) at time zone 'Asia/Manila' < c.ends_at
  union
  select h as hour from generate_series(6,21) h
  where p_booking_date=(now() at time zone 'Asia/Manila')::date
    and (p_booking_date::timestamp + make_interval(hours => h)) at time zone 'Asia/Manila' <= now();
end;
$$;

create or replace function public.expire_booking_holds()
returns void language plpgsql security definer set search_path = '' as $$
declare v_review_hours integer;
begin
  select coalesce((value->>'proof_review_hours')::integer,24) into v_review_hours
    from public.app_settings where key='booking_policy';
  update public.payments set status='rejected',rejection_reason='Payment proof review window expired',reviewed_at=now()
    where status='proof_submitted' and submitted_at < now()-make_interval(hours=>coalesce(v_review_hours,24));
  update public.bookings b set status='cancelled',updated_at=now(),
    payment_status=case when b.payment_status='proof_submitted' then 'rejected' else b.payment_status end
    where b.status='pending' and ((b.payment_status='unpaid' and b.hold_expires_at<now()) or
      (b.payment_status='proof_submitted' and not exists(select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted')));
end;
$$;

create or replace function public.create_booking(p_court_id integer, p_booking_date date, p_start_hour integer, p_duration_hours integer)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_booking public.bookings; v_start timestamptz; v_end timestamptz; v_hold_minutes integer;
begin
  if v_user is null then raise exception 'Sign in before booking'; end if;
  perform public.expire_booking_holds();
  if p_court_id not in (1,2) or p_start_hour < 6 or p_duration_hours < 1 or p_duration_hours > 16 or p_start_hour+p_duration_hours > 22 then
    raise exception 'Choose a valid court and time between 6 AM and 10 PM';
  end if;
  if p_booking_date < (now() at time zone 'Asia/Manila')::date then raise exception 'Choose a future date'; end if;
  perform pg_advisory_xact_lock(6001,p_court_id);
  select coalesce((value->>'hold_minutes')::integer,15) into v_hold_minutes from public.app_settings where key='booking_policy';
  -- Release unpaid holds and submitted proofs past the stated 24-hour review deadline.
  update public.bookings b set status='cancelled', updated_at=now()
    where b.court_id=p_court_id and b.booking_date=p_booking_date and b.status='pending'
      and ((b.payment_status='unpaid' and b.hold_expires_at < now()) or
           (b.payment_status='proof_submitted' and exists(select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted' and p.submitted_at < now()-make_interval(hours=>coalesce((select (s.value->>'proof_review_hours')::integer from public.app_settings s where s.key='booking_policy'),24)))));
  v_start := (p_booking_date::timestamp + make_interval(hours => p_start_hour)) at time zone 'Asia/Manila';
  v_end := (p_booking_date::timestamp + make_interval(hours => p_start_hour+p_duration_hours)) at time zone 'Asia/Manila';
  if v_start <= now() then raise exception 'Choose a future start time'; end if;
  if exists(select 1 from public.court_closures c where c.court_id=p_court_id and tstzrange(c.starts_at,c.ends_at,'[)') && tstzrange(v_start,v_end,'[)')) then
    raise exception 'This court is closed during the selected time';
  end if;
  insert into public.bookings(user_id,court_id,booking_date,start_hour,duration_hours,total_price,status,payment_status,hold_expires_at)
  values(v_user,p_court_id,p_booking_date,p_start_hour,p_duration_hours,p_duration_hours*250, 'pending','unpaid',now()+make_interval(mins=>coalesce(v_hold_minutes,15)))
  returning * into v_booking;
  return v_booking;
exception when exclusion_violation then raise exception 'That time overlaps another booking';
end;
$$;

create or replace function public.mark_payment_submitted()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.bookings set payment_status='proof_submitted',hold_expires_at=now()+make_interval(hours=>coalesce((select (value->>'proof_review_hours')::integer from public.app_settings where key='booking_policy'),24)),updated_at=now() where id=new.booking_id;
  return new;
end;
$$;
create trigger payment_submission_updates_booking after insert on public.payments
for each row execute function public.mark_payment_submitted();

create or replace function public.review_payment(p_payment_id uuid,p_decision text,p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.payments; b public.bookings;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_decision not in ('verify','reject') then raise exception 'Invalid review decision'; end if;
  select * into p from public.payments where id=p_payment_id for update;
  if p.id is null or p.status<>'proof_submitted' then raise exception 'Payment proof is no longer awaiting review'; end if;
  if p.submitted_at < now()-make_interval(hours=>coalesce((select (value->>'proof_review_hours')::integer from public.app_settings where key='booking_policy'),24)) then
    update public.payments set status='rejected',rejection_reason='Payment proof review window expired',reviewed_at=now(),reviewed_by=auth.uid() where id=p.id;
    update public.bookings set status='cancelled',payment_status='rejected',updated_at=now() where id=p.booking_id and status='pending';
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'payment_expired','payment',p.id,jsonb_build_object('booking_id',p.booking_id));
    return;
  end if;
  select * into b from public.bookings where id=p.booking_id for update;
  if p_decision='verify' then
    update public.payments set status='verified',reviewed_at=now(),reviewed_by=auth.uid(),rejection_reason=null where id=p.id;
    update public.bookings set payment_status='verified',status='confirmed',hold_expires_at=now(),updated_at=now() where id=b.id;
  else
    update public.payments set status='rejected',reviewed_at=now(),reviewed_by=auth.uid(),rejection_reason=coalesce(nullif(trim(p_reason),''),'Please contact the club.') where id=p.id;
    update public.bookings set payment_status='rejected',updated_at=now() where id=b.id;
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'payment_'||p_decision,'payment',p.id,jsonb_build_object('booking_id',b.id,'amount',p.amount,'reason',p_reason));
end;
$$;

create or replace function public.admin_cancel_booking(p_booking_id uuid,p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Cancellation reason is required'; end if;
  update public.bookings set status='cancelled',updated_at=now() where id=p_booking_id and status not in ('cancelled','completed');
  if not found then raise exception 'Booking cannot be cancelled'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'booking_cancelled','booking',p_booking_id,jsonb_build_object('reason',p_reason));
end;
$$;

create or replace function public.cancel_my_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v_hours integer;
begin
  select * into b from public.bookings where id=p_booking_id and user_id=auth.uid() for update;
  if b.id is null then raise exception 'Booking not found'; end if;
  select coalesce((value->>'cancellation_hours')::integer,12) into v_hours from public.app_settings where key='booking_policy';
  if b.status not in ('pending','confirmed') then raise exception 'This booking cannot be cancelled'; end if;
  if ((b.booking_date::timestamp + make_interval(hours => b.start_hour)) at time zone 'Asia/Manila') < now()+make_interval(hours=>coalesce(v_hours,12)) then
    raise exception 'Bookings must be cancelled at least % hours before start',coalesce(v_hours,12);
  end if;
  update public.bookings set status='cancelled',updated_at=now() where id=b.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'customer_booking_cancelled','booking',b.id,'{}'::jsonb);
end;
$$;

create or replace function public.admin_create_closure(p_court_id integer,p_date date,p_start_hour integer,p_end_hour integer,p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_start timestamptz; v_end timestamptz; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_court_id not in (1,2) or p_start_hour<6 or p_end_hour>22 or p_end_hour<=p_start_hour or nullif(trim(p_reason),'') is null then
    raise exception 'Enter a valid court closure between 6 AM and 10 PM with a reason';
  end if;
  if p_date < (now() at time zone 'Asia/Manila')::date then raise exception 'Choose today or a future date'; end if;
  perform pg_advisory_xact_lock(6001,p_court_id);
  v_start := (p_date::timestamp + make_interval(hours => p_start_hour)) at time zone 'Asia/Manila';
  v_end := (p_date::timestamp + make_interval(hours => p_end_hour)) at time zone 'Asia/Manila';
  if exists(select 1 from public.bookings b where b.court_id=p_court_id and b.status in ('pending','confirmed')
    and not (b.payment_status='unpaid' and b.hold_expires_at<now())
    and not (b.payment_status='proof_submitted' and exists(select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted' and p.submitted_at < now()-make_interval(hours=>coalesce((select (s.value->>'proof_review_hours')::integer from public.app_settings s where s.key='booking_policy'),24))))
    and tstzrange((b.booking_date::timestamp + make_interval(hours=>b.start_hour)) at time zone 'Asia/Manila',
                  (b.booking_date::timestamp + make_interval(hours=>b.start_hour+b.duration_hours)) at time zone 'Asia/Manila','[)') && tstzrange(v_start,v_end,'[)')) then
    raise exception 'An existing booking overlaps this closure. Cancel or reschedule it first.';
  end if;
  insert into public.court_closures(court_id,starts_at,ends_at,reason,created_by) values(p_court_id,v_start,v_end,trim(p_reason),auth.uid()) returning id into v_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'court_closed','closure',v_id,jsonb_build_object('court_id',p_court_id,'reason',p_reason));
  return v_id;
end;
$$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
revoke all on function public.get_unavailable_hours(integer,date) from public, anon;
revoke all on function public.expire_booking_holds() from public, anon;
revoke all on function public.create_booking(integer,date,integer,integer) from public, anon;
revoke all on function public.review_payment(uuid,text,text) from public, anon;
revoke all on function public.admin_cancel_booking(uuid,text) from public, anon;
revoke all on function public.cancel_my_booking(uuid) from public, anon;
revoke all on function public.admin_create_closure(integer,date,integer,integer,text) from public, anon;

alter table public.profiles enable row level security;
alter table public.courts enable row level security;
alter table public.bookings enable row level security;
alter table public.court_closures enable row level security;
alter table public.payments enable row level security;
alter table public.audit_logs enable row level security;
alter table public.app_settings enable row level security;

create policy "Profiles visible to self and admins" on public.profiles for select to authenticated using(id=(select auth.uid()) or public.is_admin());
create policy "Courts are public" on public.courts for select to anon,authenticated using(true);
create policy "Bookings visible to owner or admin" on public.bookings for select to authenticated using(user_id=(select auth.uid()) or public.is_admin());
create policy "Admins manage bookings" on public.bookings for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Closures public read" on public.court_closures for select to anon,authenticated using(true);
create policy "Admins manage closures" on public.court_closures for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Payments visible to owner or admin" on public.payments for select to authenticated using(public.is_admin() or exists(select 1 from public.bookings b where b.id=booking_id and b.user_id=(select auth.uid())));
create policy "Owner submits own proof" on public.payments for insert to authenticated with check(status='proof_submitted' and reviewed_by is null and split_part(proof_path,'/',1)=(select auth.uid())::text and split_part(proof_path,'/',2)=booking_id::text and exists(select 1 from public.bookings b where b.id=booking_id and b.user_id=(select auth.uid()) and ((b.payment_status='unpaid' and b.hold_expires_at>now()) or b.payment_status='rejected') and b.status='pending' and b.total_price=amount));
create policy "Admins manage payments" on public.payments for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Admins read audit logs" on public.audit_logs for select to authenticated using(public.is_admin());
create policy "Admins write audit logs" on public.audit_logs for insert to authenticated with check(public.is_admin());
create policy "Public settings read" on public.app_settings for select to anon,authenticated using(key in ('facility','booking_policy'));
create policy "Authenticated payment instructions read" on public.app_settings for select to authenticated using(key='payment_instructions');
create policy "Admins manage settings" on public.app_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());

grant select on public.courts,public.court_closures,public.app_settings to anon,authenticated;
grant insert,update on public.app_settings to authenticated;
grant select on public.profiles,public.bookings,public.payments to authenticated;
grant update(full_name) on public.profiles to authenticated;
grant insert(booking_id,amount,proof_path) on public.payments to authenticated;
grant execute on function public.create_booking(integer,date,integer,integer) to authenticated;
grant execute on function public.get_unavailable_hours(integer,date) to authenticated;
grant execute on function public.expire_booking_holds() to authenticated;
grant execute on function public.review_payment(uuid,text,text) to authenticated;
grant execute on function public.admin_cancel_booking(uuid,text) to authenticated;
grant execute on function public.cancel_my_booking(uuid) to authenticated;
grant execute on function public.admin_create_closure(integer,date,integer,integer,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('payment-proofs','payment-proofs',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
create policy "Customer uploads in own proof folder" on storage.objects for insert to authenticated
with check(bucket_id='payment-proofs' and (storage.foldername(name))[1]=(select auth.uid())::text and (storage.foldername(name))[2] is not null);
create policy "Customer reads own proof or admin reads proofs" on storage.objects for select to authenticated
using(bucket_id='payment-proofs' and ((storage.foldername(name))[1]=(select auth.uid())::text or public.is_admin()));
create policy "Customer replaces only own proof" on storage.objects for update to authenticated
using(bucket_id='payment-proofs' and (storage.foldername(name))[1]=(select auth.uid())::text)
with check(bucket_id='payment-proofs' and (storage.foldername(name))[1]=(select auth.uid())::text);
