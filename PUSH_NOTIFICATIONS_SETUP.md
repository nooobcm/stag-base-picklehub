# Admin push notifications deployment

Push notifications are sent by the Supabase Edge Function. Customer booking actions write one deduplicated event to the database outbox; a database trigger dispatches it, and a five-minute `pg_cron` job retries interrupted deliveries. No hold-expiration notifications are generated.

## 1. Generate VAPID keys and a dispatch secret in PowerShell

Run these from the project folder. Keep the private key and dispatch secret private; do not commit them or put them in `VITE_*` variables.

```powershell
$vapid = npx --yes web-push generate-vapid-keys --json | ConvertFrom-Json
$dispatchSecret = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')

npx supabase secrets set --project-ref skwuvvkyiczxfacivtck `
  "VAPID_PUBLIC_KEY=$($vapid.publicKey)" `
  "VAPID_PRIVATE_KEY=$($vapid.privateKey)" `
  "VAPID_SUBJECT=mailto:stagbaseadmin@gmail.com" `
  "ADMIN_PUSH_DISPATCH_SECRET=$dispatchSecret"
```

The generated VAPID pair must remain the same for all devices. Store the `$dispatchSecret` somewhere secure until the Vault step below is complete. Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions.

## 2. Store the internal database callback values in Supabase Vault

Open the production project’s SQL Editor and run this once, replacing the placeholder with the exact `$dispatchSecret` from step 1:

```sql
select vault.create_secret(
  'https://skwuvvkyiczxfacivtck.supabase.co/functions/v1/admin-push-notifications',
  'ADMIN_PUSH_FUNCTION_URL'
);

select vault.create_secret(
  'PASTE_THE_SAME_ADMIN_PUSH_DISPATCH_SECRET_HERE',
  'ADMIN_PUSH_DISPATCH_SECRET'
);
```

The Vault secret name and Edge Function secret value must match exactly. Do not add the secret values to a migration or source file.

## 3. Apply the migration and deploy the Edge Function

```powershell
npx supabase db push --remote skwuvvkyiczxfacivtck
npx supabase functions deploy admin-push-notifications --project-ref skwuvvkyiczxfacivtck
```

Then deploy the website through its existing hosting workflow so the PWA manifest, service worker, and admin settings are available on the production HTTPS domain.

## 4. Enable notifications on each admin device

Sign in as an administrator on the device and open **Admin → Booking notifications → Enable notifications**. Permission is requested only after tapping this button. Each device can be removed separately from **Registered devices**.

On iPhone/iPad, add the website to the Home Screen, open it from that icon, then enable notifications from the admin page. Web Push for Home Screen web apps requires iOS/iPadOS 16.4 or later. Android Chrome and Edge can subscribe from the browser or installed app.

## Events sent

- A customer submits a booking (one event for the single parent booking, including a two-court booking).
- A submitted booking includes a payment proof, or a proof is submitted for an already pending booking.
- A customer cancels a booking.

Creating a hold, uploading proof before submitting the booking, and abandoned checkout do not send notifications. Expired holds do not send notifications.
