begin;

create or replace function public.admin_update_court_pricing(
  p_court1_rate integer,
  p_court2_rate integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  if p_court1_rate is null or p_court1_rate<1 or p_court1_rate>100000
    or p_court2_rate is null or p_court2_rate<1 or p_court2_rate>100000 then
    raise exception 'Rates must be between ₱1 and ₱100,000 per hour';
  end if;

  update public.courts
  set hourly_rate = case id
    when 1 then p_court1_rate
    when 2 then p_court2_rate
  end
  where id in (1,2);

  if (select count(*) from public.courts where id in (1,2))<>2 then
    raise exception 'Both courts must exist before rates can be changed';
  end if;
end;
$$;

revoke all on function public.admin_update_court_pricing(integer,integer)
from public, anon;
grant execute on function public.admin_update_court_pricing(integer,integer)
to authenticated;

commit;
