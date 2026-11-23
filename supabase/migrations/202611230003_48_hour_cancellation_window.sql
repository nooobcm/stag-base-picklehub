begin;

update public.app_settings
set value=jsonb_set(coalesce(value,'{}'::jsonb),'{cancellation_hours}','48'::jsonb,true),
    updated_at=now()
where key='booking_policy';

commit;
