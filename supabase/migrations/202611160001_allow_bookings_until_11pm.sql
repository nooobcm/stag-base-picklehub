begin;

-- The final bookable slot is 10 PM–11 PM (hour 22).
-- The manual-hold booking RPC was recreated after the original hours migration,
-- so restore the 11 PM upper bound in its validation.
do $$
declare
  v_definition text;
  v_updated text;
begin
  v_definition := pg_get_functiondef(
    'public.create_guest_booking(integer,date,integer[],text,text,text)'::regprocedure
  );
  v_updated := replace(
    v_definition,
    'v_hours[cardinality(v_hours)]>21',
    'v_hours[cardinality(v_hours)]>22'
  );
  v_updated := replace(
    v_updated,
    'Choose hours between 6 AM and 10 PM',
    'Choose hours between 6 AM and 11 PM'
  );

  if v_updated = v_definition then
    raise exception 'Could not find the old booking-hour limit in create_guest_booking';
  end if;

  execute v_updated;
end;
$$;

commit;
