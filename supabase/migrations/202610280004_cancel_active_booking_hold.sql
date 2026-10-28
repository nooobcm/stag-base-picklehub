create or replace function public.cancel_my_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v_hours integer;
begin
  perform public.expire_booking_holds();
  select * into b from public.bookings
  where id=p_booking_id and user_id=auth.uid()
  for update;
  if b.id is null then raise exception 'Booking not found'; end if;

  if b.status='held' then
    if b.hold_expires_at<=now() then
      raise exception 'This payment hold has expired';
    end if;
  else
    if b.status not in ('pending','confirmed') then
      raise exception 'This booking cannot be cancelled';
    end if;
    select coalesce((value->>'cancellation_hours')::integer,12)
    into v_hours from public.app_settings where key='booking_policy';
    if ((b.booking_date::timestamp + make_interval(hours => b.start_hour)) at time zone 'Asia/Manila') < now()+make_interval(hours=>coalesce(v_hours,12)) then
      raise exception 'Bookings must be cancelled at least % hours before start',coalesce(v_hours,12);
    end if;
  end if;

  update public.bookings set status='cancelled',updated_at=now() where id=b.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'customer_booking_cancelled','booking',b.id,'{}'::jsonb);
end;
$$;
