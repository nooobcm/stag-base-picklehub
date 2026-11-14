# Stag Base Pickle Hub

Responsive court booking app for a two-court pickleball facility. The web app uses React, TypeScript, Vite, Supabase Auth, PostgreSQL, and private Supabase Storage.

## Local setup

1. Create a Supabase project.
2. In the Supabase SQL Editor, run the migration files in filename order. If migrations through guest bookings are already applied, also run [`202611150001_court_surface_pricing.sql`](supabase/migrations/202611150001_court_surface_pricing.sql) to set the new court rates. For a fresh database, run every file in `supabase/migrations` in order. If PostgREST reports a function missing after migration, run `NOTIFY pgrst, 'reload schema';` in the SQL Editor, then retry.
3. Copy `.env.example` to `.env` and set the project URL and public anon key:

   ```env
   VITE_SUPABASE_URL=https://your-project.supabase.co
   VITE_SUPABASE_ANON_KEY=your-anon-key
   ```

4. Install and run the app:

   ```sh
   npm install
   npm run dev
   ```

5. Register a user account, then promote the facility administrator from the SQL Editor. Replace the email with the account you registered:

   ```sql
   update public.profiles set is_admin = true where email = 'admin@example.com';
   ```

6. Sign in as the administrator and open `/admin` to set GCash or bank transfer instructions. Use only the Supabase public anon key in `.env`; never put a service-role key in browser code.
7. Deploy `supabase/functions/booking-confirmation-email` and set the Edge Function secrets `RESEND_API_KEY` and `BOOKING_EMAIL_FROM` to a Resend API key and a verified sender address. The function sends an email only after the admin approves a payment and the booking is confirmed.

## Booking and payment policy

- Courts are open daily from 6:00 AM to 10:00 PM, Manila time. Court 1 has a rubberized floor at ₱250/hour; Court 2 has a silica floor at ₱350/hour. Bookings use whole-hour durations, and the database enforces each court's price.
- Customers can book without signing in. Before placing the hold, they enter their name, email, and phone number. **Reserve this time** places a 10-minute hold; the customer uploads proof and presses **Book now** to submit it. Submitted bookings appear as **Waiting for confirmation** until an admin reviews the payment.
- After an admin approves and verifies payment, the app sends a confirmation email to the customer. Email delivery requires the deployed Edge Function and configured Resend secrets above.
- Customers can cancel at least 12 hours before a booking. Refunds are handled manually by the administrator and are not initiated automatically.
- Payment screenshots are JPG, PNG, or WebP files up to 5 MB in a private bucket. Uploading proof never confirms a payment; an administrator must review the actual transfer.
- Court maintenance closures are rejected if they overlap an existing pending or confirmed booking.

## Admin access and security

RLS restricts booking and payment records to their customer and authorized administrators. Guest booking links use random access tokens; only a token hash is stored in the database. Guest payment proof uploads are restricted to the matching active hold. Administrator status is assigned in the database, never by a customer form. Payment proof paths are private and access uses Storage policies and short-lived signed URLs. Booking creation and payment review run through database functions.

This repository starts without a Supabase project or credentials. Apply the migration and configure `.env` before account, booking, payment, or administrator flows can work. The public pages render before Supabase is configured.
