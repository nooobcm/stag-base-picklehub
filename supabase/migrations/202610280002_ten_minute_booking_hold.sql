-- A booking stays as a private ten-minute hold until the customer uploads proof
-- and explicitly submits it with “Book now”.
update public.app_settings
set value = value || '{"hold_minutes":10}'::jsonb, updated_at=now()
where key='booking_policy';

alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings add constraint bookings_status_check
  check(status in ('held','pending','confirmed','rejected','cancelled','completed'));

alter table public.bookings drop constraint if exists bookings_no_overlap;
alter table public.bookings add constraint bookings_no_overlap exclude using gist (
  court_id with =,
  (tstzrange((booking_date::timestamp + make_interval(hours => start_hour)) at time zone 'Asia/Manila',
             (booking_date::timestamp + make_interval(hours => start_hour + duration_hours)) at time zone 'Asia/Manila', '[)')) with &&
) where (status in ('held','pending','confirmed','completed'));

create or replace function public.expire_booking_holds()
returns void language plpgsql security definer set search_path = '' as $$
declare v_review_hours integer;
begin
  select coalesce((value->>'proof_review_hours')::integer,24) into v_review_hours
  from public.app_settings where key='booking_policy';

  update public.payments p
  set status='rejected', rejection_reason='The 10-minute booking hold expired', reviewed_at=now()
  from public.bookings b
  where p.booking_id=b.id and b.status='held' and b.hold_expires_at<now() and p.status='proof_submitted';

  update public.payments
  set status='rejected', rejection_reason='Payment proof review window expired', reviewed_at=now()
  where status='proof_submitted'
    and submitted_at < now()-make_interval(hours=>coalesce(v_review_hours,24))
    and exists(select 1 from public.bookings b where b.id=booking_id and b.status='pending');

  update public.bookings b
  set status='cancelled', updated_at=now(),
      payment_status=case when b.payment_status='proof_submitted' then 'rejected' else b.payment_status end
  where (b.status='held' and b.hold_expires_at<now())
     or (b.status='pending' and b.payment_status='unpaid' and b.hold_expires_at<now())
     or (b.status='pending' and b.payment_status='proof_submitted' and not exists(
       select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted'));
end;
$$;

create or replace function public.get_unavailable_hours(p_court_id integer,p_booking_date date)
returns table(hour integer) language plpgsql stable security definer set search_path = '' as $$
begin
  return query
  select distinct h as hour
  from public.bookings b
  cross join lateral generate_series(b.start_hour::integer,b.start_hour::integer+b.duration_hours::integer-1) h
  where b.court_id=p_court_id and b.booking_date=p_booking_date
    and b.status in ('held','pending','confirmed','completed')
    and not (b.status='held' and b.hold_expires_at<now())
    and not (b.status='pending' and b.payment_status='unpaid' and b.hold_expires_at<now())
    and not (b.status='pending' and b.payment_status='proof_submitted' and exists(
      select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted'
        and p.submitted_at<now()-make_interval(hours=>coalesce((select (s.value->>'proof_review_hours')::integer from public.app_settings s where s.key='booking_policy'),24))))
  union
  select distinct h as hour
  from public.court_closures c
  cross join lateral generate_series(6,21) h
  where c.court_id=p_court_id
    and (p_booking_date::timestamp+make_interval(hours=>h+1)) at time zone 'Asia/Manila'>c.starts_at
    and (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<c.ends_at
  union
  select h as hour from generate_series(6,21) h
  where p_booking_date=(now() at time zone 'Asia/Manila')::date
    and (p_booking_date::timestamp+make_interval(hours=>h)) at time zone 'Asia/Manila'<=now();
end;
$$;

create or replace function public.create_booking(p_court_id integer,p_booking_date date,p_start_hour integer,p_duration_hours integer)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare v_user uuid:=auth.uid(); v_booking public.bookings; v_start timestamptz; v_end timestamptz; v_hold_minutes integer;
begin
  if v_user is null then raise exception 'Sign in before booking'; end if;
  if p_court_id not in (1,2) or p_start_hour<6 or p_duration_hours<1 or p_duration_hours>16 or p_start_hour+p_duration_hours>22 then
    raise exception 'Choose a valid court and time between 6 AM and 10 PM';
  end if;
  if p_booking_date<(now() at time zone 'Asia/Manila')::date then raise exception 'Choose a future date'; end if;
  perform public.expire_booking_holds();
  perform pg_advisory_xact_lock(6001,p_court_id);
  select coalesce((value->>'hold_minutes')::integer,10) into v_hold_minutes from public.app_settings where key='booking_policy';
  v_start:=(p_booking_date::timestamp+make_interval(hours=>p_start_hour)) at time zone 'Asia/Manila';
  v_end:=(p_booking_date::timestamp+make_interval(hours=>p_start_hour+p_duration_hours)) at time zone 'Asia/Manila';
  if v_start<=now() then raise exception 'Choose a future start time'; end if;
  if exists(select 1 from public.court_closures c where c.court_id=p_court_id and tstzrange(c.starts_at,c.ends_at,'[)') && tstzrange(v_start,v_end,'[)')) then
    raise exception 'This court is closed during the selected time';
  end if;
  insert into public.bookings(user_id,court_id,booking_date,start_hour,duration_hours,total_price,status,payment_status,hold_expires_at)
  values(v_user,p_court_id,p_booking_date,p_start_hour,p_duration_hours,p_duration_hours*250,'held','unpaid',now()+make_interval(mins=>coalesce(v_hold_minutes,10)))
  returning * into v_booking;
  return v_booking;
exception when exclusion_violation then raise exception 'That time overlaps another booking';
end;
$$;

create or replace function public.mark_payment_submitted()
returns trigger language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v_review_hours integer;
begin
  select * into b from public.bookings where id=new.booking_id for update;
  if b.id is null then raise exception 'Booking hold not found'; end if;
  if b.hold_expires_at<=now() then raise exception 'The 10-minute booking hold expired'; end if;
  if b.status='held' and b.payment_status='unpaid' then
    update public.bookings set payment_status='proof_submitted',updated_at=now() where id=b.id;
  elsif b.status='pending' and b.payment_status='rejected' then
    select coalesce((value->>'proof_review_hours')::integer,24) into v_review_hours from public.app_settings where key='booking_policy';
    update public.bookings set payment_status='proof_submitted',hold_expires_at=now()+make_interval(hours=>coalesce(v_review_hours,24)),updated_at=now() where id=b.id;
  else
    raise exception 'This booking cannot accept payment proof';
  end if;
  return new;
end;
$$;

create or replace function public.confirm_booking_request(p_booking_id uuid)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v_review_hours integer;
begin
  select * into b from public.bookings where id=p_booking_id and user_id=auth.uid() for update;
  if b.id is null then raise exception 'Booking hold not found'; end if;
  if b.status<>'held' or b.hold_expires_at<=now() then raise exception 'The 10-minute hold expired. Please reserve the time again.'; end if;
  if b.payment_status<>'proof_submitted' or not exists(select 1 from public.payments p where p.booking_id=b.id and p.status='proof_submitted' and p.amount=b.total_price) then
    raise exception 'Upload payment proof before booking';
  end if;
  select coalesce((value->>'proof_review_hours')::integer,24) into v_review_hours from public.app_settings where key='booking_policy';
  update public.bookings set status='pending',payment_status='proof_submitted',hold_expires_at=now()+make_interval(hours=>coalesce(v_review_hours,24)),updated_at=now()
  where id=b.id returning * into b;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'booking_submitted','booking',b.id,jsonb_build_object('reference',b.reference,'amount',b.total_price));
  return b;
end;
$$;

create or replace function public.review_payment(p_payment_id uuid,p_decision text,p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.payments; b public.bookings;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_decision not in ('verify','reject') then raise exception 'Invalid review decision'; end if;
  select * into p from public.payments where id=p_payment_id for update;
  if p.id is null or p.status<>'proof_submitted' then raise exception 'Payment proof is no longer awaiting review'; end if;
  select * into b from public.bookings where id=p.booking_id for update;
  if b.status<>'pending' then raise exception 'Customer has not submitted this booking for confirmation'; end if;
  if p.submitted_at<now()-make_interval(hours=>coalesce((select (value->>'proof_review_hours')::integer from public.app_settings where key='booking_policy'),24)) then
    update public.payments set status='rejected',rejection_reason='Payment proof review window expired',reviewed_at=now(),reviewed_by=auth.uid() where id=p.id;
    update public.bookings set status='cancelled',payment_status='rejected',updated_at=now() where id=b.id;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'payment_expired','payment',p.id,jsonb_build_object('booking_id',b.id));
    return;
  end if;
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

create or replace function public.admin_create_closure(p_court_id integer,p_date date,p_start_hour integer,p_end_hour integer,p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_start timestamptz; v_end timestamptz; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_court_id not in (1,2) or p_start_hour<6 or p_end_hour>22 or p_end_hour<=p_start_hour or nullif(trim(p_reason),'') is null then
    raise exception 'Enter a valid court closure between 6 AM and 10 PM with a reason';
  end if;
  if p_date<(now() at time zone 'Asia/Manila')::date then raise exception 'Choose today or a future date'; end if;
  perform pg_advisory_xact_lock(6001,p_court_id);
  v_start:=(p_date::timestamp+make_interval(hours=>p_start_hour)) at time zone 'Asia/Manila';
  v_end:=(p_date::timestamp+make_interval(hours=>p_end_hour)) at time zone 'Asia/Manila';
  if exists(select 1 from public.bookings b where b.court_id=p_court_id and b.status in ('held','pending','confirmed')
    and not (b.status='held' and b.hold_expires_at<now())
    and not (b.status='pending' and b.payment_status='unpaid' and b.hold_expires_at<now())
    and tstzrange((b.booking_date::timestamp+make_interval(hours=>b.start_hour)) at time zone 'Asia/Manila',
      (b.booking_date::timestamp+make_interval(hours=>b.start_hour+b.duration_hours)) at time zone 'Asia/Manila','[)') && tstzrange(v_start,v_end,'[)')) then
    raise exception 'An existing booking overlaps this closure. Cancel or reschedule it first.';
  end if;
  insert into public.court_closures(court_id,starts_at,ends_at,reason,created_by) values(p_court_id,v_start,v_end,trim(p_reason),auth.uid()) returning id into v_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'court_closed','closure',v_id,jsonb_build_object('court_id',p_court_id,'reason',p_reason));
  return v_id;
end;
$$;

drop policy if exists "Owner submits own proof" on public.payments;
create policy "Owner submits proof for an active hold" on public.payments for insert to authenticated
with check(status='proof_submitted' and reviewed_by is null
  and split_part(proof_path,'/',1)=(select auth.uid())::text
  and split_part(proof_path,'/',2)=booking_id::text
  and exists(select 1 from public.bookings b where b.id=booking_id and b.user_id=(select auth.uid())
    and b.total_price=amount and b.hold_expires_at>now()
    and ((b.status='held' and b.payment_status='unpaid') or (b.status='pending' and b.payment_status='rejected'))));

revoke all on function public.confirm_booking_request(uuid) from public,anon;
grant execute on function public.confirm_booking_request(uuid) to authenticated;
