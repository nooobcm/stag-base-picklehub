begin;

update public.courts set name = 'The Basic' where id = 1;
update public.courts set name = 'The Pro' where id = 2;

commit;
