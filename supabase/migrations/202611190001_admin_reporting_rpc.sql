begin;

-- Keep report aggregation in Postgres. The function runs as the caller and
-- also checks admin access explicitly; booking viewers cannot read finance.
create or replace function public.admin_get_booking_report(
  p_from date,
  p_to date,
  p_granularity text default 'day',
  p_court_id integer default null,
  p_booking_status text default null,
  p_payment_status text default null,
  p_search text default null,
  p_page_size integer default 25,
  p_page_offset integer default 0,
  p_sort_by text default 'booking_date',
  p_sort_direction text default 'desc'
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_step interval;
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_page_offset integer := greatest(coalesce(p_page_offset, 0), 0);
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Choose a valid reporting date range';
  end if;
  if p_to - p_from > 3660 then
    raise exception 'Reporting ranges are limited to 10 years';
  end if;
  if p_granularity not in ('day', 'week', 'month', 'year') then
    raise exception 'Unsupported report trend interval';
  end if;
  if p_court_id is not null and p_court_id not in (1, 2) then
    raise exception 'Choose a valid court';
  end if;
  if p_sort_by not in ('reference','customer','booking_date','total_price','amount_paid','status') then
    raise exception 'Choose a valid sort column';
  end if;
  if p_sort_direction not in ('asc','desc') then
    raise exception 'Choose a valid sort direction';
  end if;

  v_step := case p_granularity
    when 'day' then interval '1 day'
    when 'week' then interval '1 week'
    when 'month' then interval '1 month'
    else interval '1 year'
  end;

  return (
    with
    period_bookings as (
      select b.*,
             coalesce(nullif(trim(b.customer_name), ''), p.full_name, 'Customer') as report_customer_name
      from public.bookings b
      left join public.profiles p on p.id = b.user_id
      where b.booking_date between p_from and p_to
        and not (b.status = 'held' and b.hold_expires_at <= now())
    ),
    payment_totals as (
      select t.booking_id, sum(t.amount)::numeric(12,2) as amount_paid,
             coalesce(jsonb_agg(distinct t.payment_method), '[]'::jsonb) as payment_methods
      from public.booking_payment_transactions t
      join period_bookings b on b.id = t.booking_id
      group by t.booking_id
    ),
    booking_base as (
      select b.*,
             coalesce(pt.amount_paid, 0)::numeric(12,2) as amount_paid,
             coalesce(pt.payment_methods, '[]'::jsonb) as payment_methods,
             case
               when b.payment_status = 'refunded' then 'refunded'
               when b.payment_status = 'proof_submitted' then 'proof_submitted'
               when b.payment_status = 'rejected' then 'rejected'
               when coalesce(pt.amount_paid, 0) >= b.total_price then 'fully_paid'
               when coalesce(pt.amount_paid, 0) > 0 then 'partially_paid'
               else 'unpaid'
             end as report_payment_status
      from period_bookings b
      left join payment_totals pt on pt.booking_id = b.id
    ),
    normalized_selections as (
      select b.id, b.booking_date, b.status,
        case
          when jsonb_typeof(b.court_selections) = 'array' then
            case when jsonb_array_length(b.court_selections) > 0 then b.court_selections
              else jsonb_build_array(jsonb_build_object(
                'court_id', b.court_id,
                'hours', case when cardinality(b.selected_hours) > 0
                  then to_jsonb(b.selected_hours)
                  else to_jsonb(array(
                    select generated_hour::smallint
                    from generate_series(b.start_hour::integer,
                      b.start_hour::integer + b.duration_hours::integer - 1) generated_hour
                  )) end
              )) end
          else jsonb_build_array(jsonb_build_object(
            'court_id', b.court_id,
            'hours', case when cardinality(b.selected_hours) > 0
              then to_jsonb(b.selected_hours)
              else to_jsonb(array(
                select generated_hour::smallint
                from generate_series(b.start_hour::integer,
                  b.start_hour::integer + b.duration_hours::integer - 1) generated_hour
              )) end
          ))
        end as selections
      from booking_base b
    ),
    selection_hours as (
      select n.id, n.booking_date, n.status,
             (selection.value->>'court_id')::integer as court_id,
             case when jsonb_typeof(selection.value->'hours') = 'array'
               then jsonb_array_length(selection.value->'hours') else 0 end::integer as booked_hours
      from normalized_selections n
      cross join lateral jsonb_array_elements(n.selections) as selection(value)
    ),
    booking_capacity as (
      select court.court_id, count(*)::numeric as available_hours
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as day_row(day_start)
      cross join generate_series(1, 2) as court(court_id)
      cross join generate_series(6, 22) as hour_row(start_hour)
      where not exists (
        select 1
        from public.court_closures closure
        where closure.court_id = court.court_id
          and closure.starts_at < ((day_row.day_start + make_interval(hours => hour_row.start_hour + 1)) at time zone 'Asia/Manila')
          and closure.ends_at > ((day_row.day_start + make_interval(hours => hour_row.start_hour)) at time zone 'Asia/Manila')
      )
      group by court.court_id
    ),
    used_hours as (
      select court_id,
             sum(booked_hours)::numeric as booked_hours,
             count(distinct id)::integer as reservations
      from selection_hours
      where status in ('confirmed', 'completed')
      group by court_id
    ),
    court_metrics as (
      select capacity.court_id,
             coalesce(used.booked_hours, 0)::numeric as booked_hours,
             capacity.available_hours,
             coalesce(used.reservations, 0)::integer as reservations,
             round(100 * coalesce(used.booked_hours, 0) / nullif(capacity.available_hours, 0), 1) as utilization_percent
      from booking_capacity capacity
      left join used_hours used on used.court_id = capacity.court_id
    ),
    summary as (
      select count(*)::integer as total_bookings,
             count(*) filter (where status in ('held', 'pending'))::integer as pending_bookings,
             count(*) filter (where status in ('confirmed', 'completed'))::integer as confirmed_bookings,
             count(*) filter (where status = 'completed')::integer as completed_bookings,
             count(*) filter (where status = 'cancelled')::integer as cancelled_bookings,
             count(*) filter (where status = 'rejected')::integer as rejected_bookings,
             count(*) filter (where report_payment_status = 'proof_submitted')::integer as proof_awaiting_review,
             count(*) filter (where status in ('confirmed', 'completed') and report_payment_status = 'fully_paid')::integer as fully_paid_bookings,
             count(*) filter (where status in ('confirmed', 'completed') and report_payment_status = 'partially_paid')::integer as partially_paid_bookings,
             count(*) filter (where status in ('confirmed', 'completed') and report_payment_status = 'unpaid')::integer as unpaid_bookings,
             coalesce(sum(total_price) filter (where status in ('confirmed', 'completed')), 0)::numeric(12,2) as confirmed_booking_value,
             coalesce(round((avg(total_price) filter (where status in ('confirmed', 'completed')))::numeric, 2), 0)::numeric(12,2) as average_booking_value,
             coalesce(sum(greatest(total_price - amount_paid, 0)) filter (
               where status in ('confirmed', 'completed') and report_payment_status <> 'refunded'
             ), 0)::numeric(12,2) as outstanding_balance,
             count(*) filter (where payment_status = 'refunded')::integer as refunded_status_bookings
      from booking_base
    ),
    transaction_window as (
      select t.amount, t.payment_method, b.status as booking_status,
             b.payment_status, date_trunc(p_granularity, t.received_at at time zone 'Asia/Manila') as bucket
      from public.booking_payment_transactions t
      join public.bookings b on b.id = t.booking_id
      where t.received_at >= (p_from::timestamp at time zone 'Asia/Manila')
        and t.received_at < ((p_to + 1)::timestamp at time zone 'Asia/Manila')
    ),
    financials as (
      select coalesce(sum(amount) filter (
               where booking_status in ('confirmed', 'completed') and payment_status <> 'refunded'
             ), 0)::numeric(12,2) as recognized_collections,
             coalesce(sum(amount), 0)::numeric(12,2) as all_recorded_collections,
             coalesce(sum(amount) filter (where booking_status in ('cancelled', 'rejected')), 0)::numeric(12,2) as cancelled_booking_collections,
             coalesce(sum(amount) filter (where payment_status = 'refunded'), 0)::numeric(12,2) as refunded_status_collections,
             coalesce(sum(amount) filter (
               where booking_status in ('confirmed', 'completed') and payment_status <> 'refunded' and payment_method = 'cash'
             ), 0)::numeric(12,2) as cash_collections,
             coalesce(sum(amount) filter (
               where booking_status in ('confirmed', 'completed') and payment_status <> 'refunded' and payment_method = 'online'
             ), 0)::numeric(12,2) as online_collections
      from transaction_window
    ),
    booking_trend_values as (
      select date_trunc(p_granularity, booking_date::timestamp) as bucket, count(*)::integer as value
      from booking_base
      group by 1
    ),
    revenue_trend_values as (
      select bucket, sum(amount)::numeric(12,2) as value
      from transaction_window
      where booking_status in ('confirmed', 'completed') and payment_status <> 'refunded'
      group by bucket
    ),
    trend_buckets as (
      select generate_series(
        date_trunc(p_granularity, p_from::timestamp),
        date_trunc(p_granularity, p_to::timestamp), v_step
      ) as bucket
    ),
    trend_data as (
      select coalesce((select jsonb_agg(jsonb_build_object(
                 'period', buckets.bucket::date,
                 'value', coalesce(bookings.value, 0)
               ) order by buckets.bucket)
               from trend_buckets buckets
               left join booking_trend_values bookings using (bucket)), '[]'::jsonb) as bookings,
             coalesce((select jsonb_agg(jsonb_build_object(
                 'period', buckets.bucket::date,
                 'value', coalesce(revenue.value, 0)
               ) order by buckets.bucket)
               from trend_buckets buckets
               left join revenue_trend_values revenue using (bucket)), '[]'::jsonb) as revenue
    ),
    payment_status_data as (
      select coalesce(jsonb_object_agg(status, count), '{}'::jsonb) as values
      from (
        select report_payment_status as status, count(*)::integer as count
        from booking_base
        where status in ('confirmed', 'completed')
        group by report_payment_status
      ) statuses
    ),
    normalized_filters as (
      select b.*,
        coalesce((select jsonb_agg(method order by method)
                  from (select distinct t.payment_method as method
                        from public.booking_payment_transactions t where t.booking_id = b.id) methods), '[]'::jsonb) as report_payment_methods
      from booking_base b
    ),
    filtered_bookings as (
      select b.*,
        row_number() over (order by
          case when p_sort_by = 'reference' and p_sort_direction = 'asc' then lower(b.reference) end asc,
          case when p_sort_by = 'reference' and p_sort_direction = 'desc' then lower(b.reference) end desc,
          case when p_sort_by = 'customer' and p_sort_direction = 'asc' then lower(b.report_customer_name) end asc,
          case when p_sort_by = 'customer' and p_sort_direction = 'desc' then lower(b.report_customer_name) end desc,
          case when p_sort_by = 'booking_date' and p_sort_direction = 'asc' then b.booking_date end asc,
          case when p_sort_by = 'booking_date' and p_sort_direction = 'desc' then b.booking_date end desc,
          case when p_sort_by = 'total_price' and p_sort_direction = 'asc' then b.total_price end asc,
          case when p_sort_by = 'total_price' and p_sort_direction = 'desc' then b.total_price end desc,
          case when p_sort_by = 'amount_paid' and p_sort_direction = 'asc' then b.amount_paid end asc,
          case when p_sort_by = 'amount_paid' and p_sort_direction = 'desc' then b.amount_paid end desc,
          case when p_sort_by = 'status' and p_sort_direction = 'asc' then b.status end asc,
          case when p_sort_by = 'status' and p_sort_direction = 'desc' then b.status end desc,
          b.booking_date desc, b.created_at desc, b.id
        ) as report_order
      from normalized_filters b
      where (p_booking_status is null or b.status = p_booking_status)
        and (p_payment_status is null or b.report_payment_status = p_payment_status)
        and (p_court_id is null or exists (
          select 1 from selection_hours selected
          where selected.id = b.id and selected.court_id = p_court_id
        ))
        and (nullif(trim(coalesce(p_search, '')), '') is null
          or b.reference ilike '%' || trim(p_search) || '%'
          or b.report_customer_name ilike '%' || trim(p_search) || '%')
    ),
    table_page as (
      select b.report_order, b.id, b.reference, b.user_id, b.court_id, b.booking_date,
             b.start_hour, b.duration_hours, b.selected_hours, b.court_selections,
             b.total_price, b.status, b.payment_status, b.payment_method,
             b.created_at, b.hold_expires_at, b.customer_name, b.customer_email, b.customer_phone,
             b.report_customer_name, b.amount_paid,
             case when b.report_payment_status = 'refunded' then null
                  else greatest(b.total_price - b.amount_paid, 0) end as outstanding_balance,
             b.report_payment_status, b.report_payment_methods
      from filtered_bookings b
      order by b.report_order
      limit v_page_size offset v_page_offset
    ),
    table_data as (
      select (select count(*)::integer from filtered_bookings) as total_count,
             coalesce((select jsonb_agg(to_jsonb(page) - 'report_order' order by page.report_order)
                       from table_page page), '[]'::jsonb) as rows
    )
    select jsonb_build_object(
      'period', jsonb_build_object('from', p_from, 'to', p_to, 'timezone', 'Asia/Manila'),
      'summary', (select to_jsonb(summary) from summary),
      'financials', (select to_jsonb(financials) from financials),
      'courts', coalesce((select jsonb_agg(jsonb_build_object(
        'court_id', court_id, 'booked_hours', booked_hours,
        'available_hours', available_hours, 'reservations', reservations,
        'utilization_percent', utilization_percent
      ) order by court_id) from court_metrics), '[]'::jsonb),
      'utilization', jsonb_build_object(
        'booked_hours', coalesce((select sum(booked_hours) from court_metrics), 0),
        'available_hours', coalesce((select sum(available_hours) from court_metrics), 0),
        'percent', coalesce(round(100 * (select sum(booked_hours) from court_metrics) /
          nullif((select sum(available_hours) from court_metrics), 0), 1), 0)
      ),
      'payment_status', (select values from payment_status_data),
      'trends', (select jsonb_build_object('bookings', bookings, 'revenue', revenue) from trend_data),
      'table', (select jsonb_build_object('total', total_count, 'rows', rows) from table_data),
      'notes', jsonb_build_object(
        'booking_date_basis', 'Booking metrics and court use are grouped by the reserved date.',
        'revenue_date_basis', 'Collections are grouped by the transaction received date in Asia/Manila.',
        'refunds', 'The schema stores a refunded status but does not record refund amounts. Receipts tied to refunded bookings are excluded from recognized collections and shown separately.'
      )
    )
  );
end;
$$;

revoke all on function public.admin_get_booking_report(date,date,text,integer,text,text,text,integer,integer,text,text) from public, anon;
grant execute on function public.admin_get_booking_report(date,date,text,integer,text,text,text,integer,integer,text,text) to authenticated;

commit;
