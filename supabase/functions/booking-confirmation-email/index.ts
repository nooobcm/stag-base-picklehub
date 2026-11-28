import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const escapeHtml = (value: string) => value.replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[char]!))

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return Response.json({ error: 'Method not allowed' }, { status: 405, headers: cors })

  const url = Deno.env.get('SUPABASE_URL')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const resendKey = Deno.env.get('RESEND_API_KEY')
  const from = Deno.env.get('BOOKING_EMAIL_FROM')
  if (!resendKey || !from) return Response.json({ error: 'Booking email is not configured.' }, { status: 503, headers: cors })

  const authorization = request.headers.get('Authorization')
  if (!authorization) return Response.json({ error: 'Sign in as an administrator.' }, { status: 401, headers: cors })
  const db = createClient(url, serviceKey)
  const accessToken = authorization.replace(/^Bearer\s+/i, '').trim()
  const { data: { user }, error: authError } = await db.auth.getUser(accessToken)
  if (authError || !user) {
    console.error('Confirmation email admin authentication failed:', authError?.message || 'No user found')
    return Response.json({ error: 'Admin session is invalid or expired. Sign out and sign back in, then retry.' }, { status: 401, headers: cors })
  }

  const { data: profile } = await db.from('profiles').select('is_admin').eq('id', user.id).maybeSingle()
  if (!profile?.is_admin) return Response.json({ error: 'Administrator access required.' }, { status: 403, headers: cors })

  const { booking_id } = await request.json()
  if (!booking_id) return Response.json({ error: 'Booking id is required.' }, { status: 400, headers: cors })
  const { data: booking, error: bookingError } = await db.from('bookings')
    .select('id,reference,court_id,court_selections,booking_date,start_hour,duration_hours,selected_hours,total_price,paddle_count,paddle_fee,status,payment_status,payment_method,customer_name,customer_email,confirmation_email_sent_at,profiles(full_name,email)')
    .eq('id', booking_id).single()
  if (bookingError || !booking) return Response.json({ error: 'Booking not found.' }, { status: 404, headers: cors })
  if (booking.status !== 'confirmed') {
    return Response.json({ error: 'Only confirmed bookings can receive a confirmation email.' }, { status: 409, headers: cors })
  }
  if (booking.confirmation_email_sent_at) return Response.json({ sent: true, already_sent: true }, { headers: cors })

  const recipient = booking.customer_email || booking.profiles?.email
  if (!recipient) return Response.json({ error: 'No customer email is saved for this booking.' }, { status: 422, headers: cors })
  const { data: paymentRows } = await db.from('booking_payment_transactions').select('amount').eq('booking_id', booking.id)
  const totalReceived = (paymentRows || []).reduce((sum, payment) => sum + Number(payment.amount || 0), 0)
  const remainingBalance = Math.max(0, Number(booking.total_price) - totalReceived)
  const customerName = booking.customer_name || booking.profiles?.full_name || 'there'
  const selections: { court_id:number; hours:number[] }[] = booking.court_selections?.length
    ? booking.court_selections
    : [{ court_id:booking.court_id, hours:booking.selected_hours?.length ? booking.selected_hours : Array.from({ length: booking.duration_hours }, (_value, index) => booking.start_hour + index) }]
  const start = new Date(`${booking.booking_date}T${String(Math.min(...selections.flatMap(selection => selection.hours))).padStart(2, '0')}:00:00+08:00`)
  const timeLabel = (hour: number) => new Date(`${booking.booking_date}T${String(hour % 24).padStart(2, '0')}:00:00+08:00`).toLocaleTimeString('en-PH', { timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit' })
  const formatRanges = (hours: number[]) => {
    const intervals: number[][] = []
    for (const hour of [...new Set(hours)].sort((a, b) => a - b)) {
      const latest = intervals.at(-1)
      if (latest && hour === latest.at(-1)! + 1) latest.push(hour)
      else intervals.push([hour])
    }
    return intervals.map(hours => `${timeLabel(hours[0])} – ${timeLabel(hours.at(-1)! + 1)}`).join(', ')
  }
  const bookingTime = selections.map(selection => `${selection.court_id === 1 ? 'The Basic · Court 1' : 'The Pro · Court 2'}: ${formatRanges(selection.hours)}`).join('\n')
  const rentalHours = new Set(selections.flatMap(selection => selection.hours)).size
  const paddleSummaryHtml = Number(booking.paddle_count || 0) > 0
    ? `<p><b>Paddle rental:</b> ${Number(booking.paddle_count)} paddle${Number(booking.paddle_count) === 1 ? '' : 's'} · ${rentalHours} hour${rentalHours === 1 ? '' : 's'} · ₱${Number(booking.paddle_fee || 0).toLocaleString('en-PH')}</p>`
    : ''
  const paddleSummaryText = Number(booking.paddle_count || 0) > 0
    ? `Paddle rental: ${Number(booking.paddle_count)} paddle${Number(booking.paddle_count) === 1 ? '' : 's'} · ${rentalHours} hour${rentalHours === 1 ? '' : 's'} · ₱${Number(booking.paddle_fee || 0).toLocaleString('en-PH')}`
    : ''
  const dateLabel = start.toLocaleDateString('en-PH', { timeZone: 'Asia/Manila', weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })
  const safeName = escapeHtml(customerName)
  const safeReference = escapeHtml(booking.reference)
  const courtName = selections.map(selection => selection.court_id === 1 ? 'The Basic · Court 1' : 'The Pro · Court 2').join(' + ')
  const safeCourt = escapeHtml(courtName)
  const safeDate = escapeHtml(dateLabel)
  const safeTime = escapeHtml(bookingTime)
  const paymentHtml = booking.payment_status === 'verified' || booking.payment_status === 'fully_paid'
    ? `<p><b>Total paid:</b> ₱${totalReceived.toLocaleString('en-PH')}</p><p><b>Status:</b> Booked · Fully paid</p>`
    : booking.payment_status === 'partially_paid'
      ? `<p><b>Deposit received:</b> ₱${totalReceived.toLocaleString('en-PH')}</p><p><b>Remaining balance:</b> ₱${remainingBalance.toLocaleString('en-PH')}</p><p><b>Status:</b> Booking confirmed with deposit</p>`
    : booking.payment_method === 'cash'
      ? `<p><b>Amount due:</b> ₱${Number(booking.total_price).toLocaleString('en-PH')}</p><p><b>Payment method:</b> Cash at the court</p><p>Please pay in cash when you arrive.</p>`
      : `<p><b>Amount due:</b> ₱${Number(booking.total_price).toLocaleString('en-PH')}</p><p><b>Status:</b> Booked · Payment due</p><p>You may pay later by GCash. Account name: <b>M* AN***A S.</b><br>GCash number: <b>09052692785</b></p>`
  const paymentText = booking.payment_status === 'verified' || booking.payment_status === 'fully_paid'
    ? `Total paid: ₱${totalReceived.toLocaleString('en-PH')}\nStatus: Booked · Fully paid`
    : booking.payment_status === 'partially_paid'
      ? `Deposit received: ₱${totalReceived.toLocaleString('en-PH')}\nRemaining balance: ₱${remainingBalance.toLocaleString('en-PH')}\nStatus: Booking confirmed with deposit`
    : booking.payment_method === 'cash'
      ? `Amount due: ₱${Number(booking.total_price).toLocaleString('en-PH')}\nPayment method: Cash at the court\nPlease pay in cash when you arrive.`
      : `Amount due: ₱${Number(booking.total_price).toLocaleString('en-PH')}\nStatus: Booked · Payment due\n\nYou may pay later by GCash. Account name: M* AN***A S.\nGCash number: 09052692785`
  const introHtml = booking.payment_status === 'verified' || booking.payment_status === 'fully_paid'
    ? `Hi ${safeName}, your payment has been verified and your booking is confirmed.`
    : booking.payment_status === 'partially_paid'
      ? `Hi ${safeName}, your booking is confirmed with a deposit. The remaining balance is due at the court.`
    : booking.payment_method === 'cash'
      ? `Hi ${safeName}, your booking is confirmed. Please pay in cash at the court when you arrive.`
      : `Hi ${safeName}, your booking is confirmed. Payment is not required to reserve now; you may pay later using the GCash details below.`
  const introText = booking.payment_status === 'verified' || booking.payment_status === 'fully_paid'
    ? `Hi ${customerName}, your payment has been verified and your booking is confirmed.`
    : booking.payment_status === 'partially_paid'
      ? `Hi ${customerName}, your booking is confirmed with a deposit. The remaining balance is due at the court.`
    : booking.payment_method === 'cash'
      ? `Hi ${customerName}, your booking is confirmed. Please pay in cash at the court when you arrive.`
      : `Hi ${customerName}, your booking is confirmed. Payment is not required to reserve now; you may pay later using the GCash details below.`
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json', 'Idempotency-Key': `booking-confirmation-${booking.id}` },
    body: JSON.stringify({
      from, to: [recipient], subject: `Court booking confirmed · ${booking.reference}`,
      html: `<div style="font-family:Arial,sans-serif;color:#203529;max-width:560px;margin:auto"><h1>Your court is confirmed!</h1><p>${introHtml}</p><div style="padding:18px;background:#f0f4e9;border-radius:8px"><p><b>Booking reference:</b> ${safeReference}</p><p><b>Court(s):</b> ${safeCourt}</p><p><b>Date:</b> ${safeDate}</p><p><b>Time:</b><br>${safeTime.replaceAll('\n','<br>')}</p><p><b>Total reserved court hours:</b> ${selections.reduce((sum,selection)=>sum+selection.hours.length,0)}</p>${paddleSummaryHtml}${paymentHtml}</div><p>We look forward to seeing you at Stag Base Pickle Hub.</p></div>`,
      text: `Your court is confirmed!\n\n${introText}\n\nBooking reference: ${booking.reference}\nCourt(s): ${courtName}\nDate: ${dateLabel}\nTime:\n${bookingTime}\nTotal reserved court hours: ${selections.reduce((sum,selection)=>sum+selection.hours.length,0)}\n${paddleSummaryText ? `${paddleSummaryText}\n` : ''}${paymentText}\n\nWe look forward to seeing you at Stag Base Pickle Hub.`,
    }),
  })
  if (!response.ok) {
    const providerError = await response.json().catch(() => null) as { message?: string; name?: string } | null
    const detail = providerError?.message || providerError?.name || `Email provider returned HTTP ${response.status}`
    return Response.json({ error: `Booking was approved, but the email provider rejected the confirmation: ${detail}` }, { status: 502, headers: cors })
  }
  const { error: updateError } = await db.from('bookings').update({ confirmation_email_sent_at: new Date().toISOString() }).eq('id', booking.id)
  if (updateError) return Response.json({ error: 'Email sent, but its delivery record could not be saved.' }, { status: 500, headers: cors })
  return Response.json({ sent: true }, { headers: cors })
})
