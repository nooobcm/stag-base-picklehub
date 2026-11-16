begin;

-- The booking page can be used with or without an active customer session.
-- The security-definer RPC still validates the booking input and creates a
-- guest access token, so permit both PostgREST roles to call it.
grant execute on function public.create_guest_booking_multi(date,jsonb,text,text,text,text)
  to anon, authenticated;

commit;
