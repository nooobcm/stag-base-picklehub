# Stag Base Pickle Hub

Responsive court booking app for a two-court pickleball facility. The web app uses React, TypeScript, Vite, Supabase Auth, PostgreSQL, and private Supabase Storage.

## Local setup

1. Create a Supabase project.
2. In the Supabase SQL Editor, run the migration files in filename order: [`202610280001_initial_booking_system.sql`](supabase/migrations/202610280001_initial_booking_system.sql), then [`202610280002_ten_minute_booking_hold.sql`](supabase/migrations/202610280002_ten_minute_booking_hold.sql). If the initial migration was already applied, run only the new second migration.
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

## Booking and payment policy

- Courts are open daily from 6:00 AM to 10:00 PM, Manila time. Bookings use whole-hour durations and the database calculates ₱250 per hour.
- Clicking **Reserve this time** places a 10-minute hold. The customer uploads proof, then clicks **Book now** to submit it. Submitted bookings appear as **Waiting for confirmation** until an admin reviews the payment. Proof stays in manual review for up to 24 hours.
- Customers can cancel at least 12 hours before a booking. Refunds are handled manually by the administrator and are not initiated automatically.
- Payment screenshots are JPG, PNG, or WebP files up to 5 MB in a private bucket. Uploading proof never confirms a payment; an administrator must review the actual transfer.
- Court maintenance closures are rejected if they overlap an existing pending or confirmed booking.

## Admin access and security

RLS restricts booking and payment records to their customer and authorized administrators. Administrator status is assigned in the database, never by a customer form. Payment proof paths are private and access uses authenticated Storage policies and short-lived signed URLs. Booking creation and payment review run through database functions.

This repository starts without a Supabase project or credentials. Apply the migration and configure `.env` before account, booking, payment, or administrator flows can work. The public pages render before Supabase is configured.
