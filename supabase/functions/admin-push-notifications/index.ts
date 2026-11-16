import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-admin-push-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

type PushSubscription = {
  endpoint: string
  keys: { p256dh: string; auth: string }
}

const json = (body: unknown, status = 200) => Response.json(body, { status, headers: cors })

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const url = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!url || !serviceKey) return json({ error: 'Push service is not configured.' }, 503)

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  let body: Record<string, unknown>
  try { body = await request.json() } catch { return json({ error: 'Request body must be valid JSON.' }, 400) }

  // Database-triggered delivery is authenticated with a secret stored in Vault.
  const dispatchSecret = Deno.env.get('ADMIN_PUSH_DISPATCH_SECRET')
  if (dispatchSecret && request.headers.get('x-admin-push-secret') === dispatchSecret) {
    return await dispatchEvent(db, String(body.event_id || ''))
  }

  // Every browser action is checked against the signed-in Supabase user and admin profile.
  const accessToken = (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
  if (!accessToken) return json({ error: 'Sign in as an administrator.' }, 401)
  const { data: { user }, error: authError } = await db.auth.getUser(accessToken)
  if (authError || !user) return json({ error: 'Admin session is invalid or expired. Sign in again.' }, 401)
  const { data: profile } = await db.from('profiles').select('is_admin').eq('id', user.id).maybeSingle()
  if (!profile?.is_admin) return json({ error: 'Administrator access required.' }, 403)

  const action = String(body.action || '')
  if (action === 'list') {
    const { data, error } = await db.from('admin_push_subscriptions')
      .select('id,endpoint,device_label,created_at,last_used_at')
      .eq('admin_user_id', user.id).order('created_at', { ascending: false })
    if (error) return json({ error: error.message }, 500)
    return json({
      devices: data || [],
      public_key: Deno.env.get('VAPID_PUBLIC_KEY') || null,
      configured: Boolean(Deno.env.get('VAPID_PUBLIC_KEY') && Deno.env.get('VAPID_PRIVATE_KEY')),
    })
  }

  if (action === 'subscribe') {
    const subscription = body.subscription as PushSubscription | undefined
    if (!subscription?.endpoint || !subscription.keys?.p256dh || !subscription.keys?.auth) {
      return json({ error: 'The browser returned an invalid push subscription.' }, 400)
    }
    const userAgent = request.headers.get('user-agent') || 'This device'
    const deviceLabel = userAgent.includes('iPhone') || userAgent.includes('iPad')
      ? 'Apple device' : userAgent.includes('Android') ? 'Android device' : 'Browser device'
    const { error } = await db.from('admin_push_subscriptions').upsert({
      admin_user_id: user.id,
      endpoint: subscription.endpoint,
      subscription,
      device_label: deviceLabel,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'endpoint' })
    if (error) return json({ error: error.message }, 500)
    return json({ saved: true })
  }

  if (action === 'remove') {
    const subscriptionId = String(body.subscription_id || '')
    if (!subscriptionId) return json({ error: 'Select a device to remove.' }, 400)
    const { error } = await db.from('admin_push_subscriptions').delete()
      .eq('id', subscriptionId).eq('admin_user_id', user.id)
    if (error) return json({ error: error.message }, 500)
    return json({ removed: true })
  }

  return json({ error: 'Unknown push notification action.' }, 400)
})

async function dispatchEvent(db: ReturnType<typeof createClient>, eventId: string) {
  if (!/^[0-9a-f-]{36}$/i.test(eventId)) return json({ error: 'Invalid notification event.' }, 400)
  const { data: event, error: eventError } = await db.from('admin_push_outbox')
    .select('id,event_type,booking_id,payload,status').eq('id', eventId).maybeSingle()
  if (eventError || !event) return json({ error: 'Notification event not found.' }, 404)
  if (event.status === 'sent') return json({ sent: true, already_sent: true })

  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY')
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY')
  const subject = Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@stagbaseph.com'
  if (!publicKey || !privateKey) {
    await db.from('admin_push_outbox').update({ status: 'queued', last_error: 'VAPID keys are not configured.' }).eq('id', eventId)
    return json({ error: 'VAPID keys are not configured.' }, 503)
  }
  webpush.setVapidDetails(subject, publicKey, privateKey)

  const { data: subscriptions, error: subscriptionError } = await db.from('admin_push_subscriptions')
    .select('id,subscription')
  if (subscriptionError) {
    await db.from('admin_push_outbox').update({ status: 'queued', last_error: subscriptionError.message }).eq('id', eventId)
    return json({ error: 'Could not load administrator devices.' }, 500)
  }
  if (!subscriptions?.length) {
    await db.from('admin_push_outbox').update({ status: 'sent', sent_at: new Date().toISOString(), last_error: 'No admin devices were registered.' }).eq('id', eventId)
    return json({ sent: true, devices: 0 })
  }

  const payload = JSON.stringify({
    title: event.payload?.title || 'Stag Base update',
    body: event.payload?.body || 'A booking has been updated.',
    tag: `${event.event_type}:${event.booking_id}`,
    data: { url: `/admin?bookingId=${encodeURIComponent(event.booking_id)}` },
  })
  let retry = false
  const failures: string[] = []

  for (const device of subscriptions) {
    const { data: previous } = await db.from('admin_push_deliveries')
      .select('status,attempts').eq('event_id', eventId).eq('subscription_id', device.id).maybeSingle()
    if (previous?.status === 'sent') continue

    await db.from('admin_push_deliveries').upsert({
      event_id: eventId, subscription_id: device.id, status: 'sending',
      attempts: (previous?.attempts || 0) + 1,
    }, { onConflict: 'event_id,subscription_id' })
    const subscription = device.subscription as PushSubscription
    try {
      await webpush.sendNotification(subscription, payload, { TTL: 60 * 60 })
      await db.from('admin_push_deliveries').upsert({
        event_id: eventId, subscription_id: device.id, status: 'sent',
        sent_at: new Date().toISOString(), last_error: null,
      }, { onConflict: 'event_id,subscription_id' })
      await db.from('admin_push_subscriptions').update({ last_used_at: new Date().toISOString() }).eq('id', device.id)
    } catch (error) {
      const status = Number((error as { statusCode?: number }).statusCode)
      if (status === 404 || status === 410) {
        await db.from('admin_push_subscriptions').delete().eq('id', device.id)
        continue
      }
      const detail = error instanceof Error ? error.message : 'Push delivery failed.'
      await db.from('admin_push_deliveries').upsert({
        event_id: eventId, subscription_id: device.id, status: 'queued',
        last_error: detail.slice(0, 800),
      }, { onConflict: 'event_id,subscription_id' })
      failures.push(detail)
      retry = true
    }
  }

  await db.from('admin_push_outbox').update({
    status: retry ? 'queued' : 'sent',
    sent_at: retry ? null : new Date().toISOString(),
    last_error: failures.length ? failures.join('; ').slice(0, 1000) : null,
  }).eq('id', eventId)
  return json({ sent: !retry, retry, devices: subscriptions.length })
}
