# Build a Pickleball Court Booking Website

Act as a senior full-stack developer. Build a clean, modern, responsive Pickleball Court Booking Website in my existing project.

I am a beginner, so keep the code understandable, organized, secure, and easy to maintain.

## 1. Inspect the Existing Project

Before coding:
- Inspect the existing project structure and installed dependencies.
- Identify the current frontend, Supabase setup, database schema, authentication, routes, and tests.
- Reuse existing code and components where possible.
- Preserve working features, existing migrations, RLS policies, and database tests.
- Do not recreate the project or rewrite working features unnecessarily.
- Do not modify unrelated files.

Start by briefly reporting your findings and implementation plan. Then proceed with small, focused changes.

## 2. Technology Stack

Use the existing setup where possible:
- React
- TypeScript
- Vite
- Tailwind CSS
- React Router
- Supabase Authentication
- Supabase PostgreSQL
- Supabase Storage
- Lucide React icons
- React Hook Form and Zod, if appropriate

Do not install unnecessary dependencies or upgrade packages without a clear reason.

## 3. Business Requirements

This is a small pickleball facility with exactly two courts.

- Court 1
- Court 2
- Rental price: ₱250 per court per hour
- Operating days: Daily
- Operating hours: 6:00 AM–10:00 PM
- Minimum booking duration: 1 hour
- Booking durations: Whole-hour increments
- Time zone: Asia/Manila
- Payment method: Manual GCash or bank transfer
- Payment proof: Customer uploads a screenshot or photo
- Payment verification: Manual administrator approval
- Do not integrate PayMongo or other payment gateways.

Calculate all booking prices using trusted server/database-side logic.

## 4. Website Design

Create a professional, modern sports-booking website.

Design direction:
- Clean, sporty, premium appearance
- White or light background
- Green accents inspired by pickleball courts
- Dark, readable typography
- Rounded cards and buttons
- Consistent spacing and typography
- Responsive desktop, tablet, and mobile layouts
- Clear navigation and intuitive forms
- Subtle hover effects only where useful
- Loading indicators, empty states, error messages, and success notifications

Avoid unnecessary animations, excessive gradients, cluttered layouts, and oversized components.

Create a consistent design system for colors, buttons, inputs, cards, dialogs, and status badges.

Do not change the existing visual design unnecessarily if the project already has a good design.

## 5. Public Website

Create these pages:

### Home
- Attractive hero section introducing the pickleball facility
- Clear “Book a Court” call-to-action
- Display both courts
- Show the hourly rate of ₱250
- Show operating hours
- Explain the booking and payment process
- Include a simple footer with contact information configured by the administrator

### Courts
- Display Court 1 and Court 2
- Show court availability where appropriate
- Display the hourly rental price
- Provide a booking button for each court

### Login
- Email and password login
- Form validation
- Loading and error states
- Link to registration and password reset

### Registration
- Full name
- Email
- Password
- Confirm password
- Appropriate validation and error handling

### Password Reset
- Allow users to request a password-reset email through Supabase Auth.

## 6. Customer Dashboard

After logging in, customers should see a dedicated dashboard.

Include:
- Welcome message
- Quick booking button
- Upcoming bookings
- Booking history
- Payment status
- Booking status
- Booking reference numbers

### Book a Court
Create a booking interface where customers can:
1. Select Court 1 or Court 2.
2. Select a date.
3. View available time slots.
4. Select a starting time.
5. Select a duration in whole hours.
6. View the price calculation.
7. Review the booking details.
8. Submit the booking.

Price examples:
- 1 hour = ₱250
- 2 hours = ₱500
- 3 hours = ₱750

Only display valid time slots within 6:00 AM–10:00 PM.

Check availability again on the server/database when creating a booking. Prevent overlapping bookings, including simultaneous requests.

### My Bookings
Display bookings with:
- Booking reference
- Court
- Date
- Start and end times
- Duration
- Total price
- Booking status
- Payment status

Allow customers to open booking details and cancel eligible bookings according to the configured cancellation policy.

Customers must only access their own bookings.

### Payment
After a booking is created:
- Display the total amount due.
- Display the administrator's GCash or bank transfer instructions.
- Let the customer upload payment proof.
- Show whether payment proof is awaiting verification, verified, or rejected.
- Display the rejection reason when applicable.
- Allow replacement proof after rejection.

Accept JPG, JPEG, PNG, and WebP images up to 5 MB.

Store payment proof in a private Supabase Storage bucket. Customers must not be able to access other customers' private files.

An uploaded screenshot must never automatically mark a payment as verified.

## 7. Administrator Dashboard

Create a separate, protected admin interface.

### Dashboard Overview
Display:
- Total bookings
- Today's bookings
- Pending bookings
- Payments awaiting verification
- Confirmed bookings
- Revenue from verified payments
- Court availability

### Booking Management
Administrators can:
- View all bookings
- Search and filter by date, court, customer, and status
- View booking details
- Approve or reject bookings where appropriate
- Cancel bookings with a reason
- View booking and payment histories

### Payment Verification
Administrators can:
- View submitted payment proofs
- Securely open uploaded screenshots
- View customer and booking information
- See the expected payment amount
- Verify payment after checking the actual GCash or bank transaction
- Reject proof with a reason
- Track verification history

Only authorized administrators can verify payments.

### Court Management
Administrators can:
- View both courts
- Close a court temporarily for maintenance
- Set closure dates and times
- Enter closure reasons
- Prevent bookings during closed periods

Handle existing bookings safely when a court closure is created.

### Customer Management
Administrators can:
- View registered customers
- Search customers
- View relevant booking histories

### Reports
Provide basic reports with date filters:
- Total bookings
- Bookings by court
- Confirmed, cancelled, and rejected bookings
- Court utilization
- Verified payment totals and revenue

Do not count unpaid or unverified bookings as received revenue.

### Settings
Allow administrators to configure:
- Facility name and contact information
- GCash or bank transfer payment instructions
- Booking hold duration
- Cancellation policy
- Other essential business settings

Do not expose administrative secrets in frontend code.

## 8. Booking and Payment Rules

Use separate booking and payment statuses.

Suggested booking statuses:
- `pending`
- `confirmed`
- `rejected`
- `cancelled`
- `completed`

Suggested payment statuses:
- `unpaid`
- `proof_submitted`
- `verified`
- `rejected`
- `refunded`

Maintain consistent transitions between statuses.

Suggested booking process:

1. Customer selects a court and time.
2. System validates availability and calculates the total.
3. Booking is created and the slot is temporarily held.
4. Customer receives payment instructions.
5. Customer uploads proof of payment.
6. Admin checks the actual transaction.
7. Admin verifies or rejects the proof.
8. A verified payment leads to confirmation according to the booking policy.

Define a reasonable temporary hold duration, such as 15 minutes, and handle expired unpaid bookings safely. Submitted proof must have a clear verification deadline or expiration policy.

Explain the proposed policy before implementation if it conflicts with existing database logic.

## 9. Database and Security

Inspect the existing Supabase schema before adding tables.

Reuse existing tables where appropriate. If necessary, use structures for:
- User profiles
- Courts
- Bookings
- Payments
- Court closures
- Audit logs
- Application settings

Requirements:
- Enable and correctly configure Row Level Security.
- Customers can access only their own private data.
- Customers cannot assign themselves admin privileges.
- Only authorized administrators can access admin operations.
- Validate prices, booking times, and status changes on the server/database side.
- Prevent overlapping bookings using concurrency-safe database logic.
- Use foreign keys, constraints, and indexes where appropriate.
- Use private Supabase Storage for payment screenshots.
- Protect uploaded files with appropriate Storage policies.
- Never expose the Supabase service-role key in browser code.
- Never trust client-supplied payment statuses, roles, or totals.
- Use secure server-side functions or Edge Functions when needed.
- Keep sensitive payment information out of logs.

Create new migrations for schema changes. Do not silently modify migrations that have already been applied.

## 10. Testing

Test the important features:
- Authentication and route protection
- Customer and administrator permissions
- Price calculations
- Opening hours and booking durations
- Court closures
- Double-booking prevention
- Concurrent booking attempts
- Expired booking holds
- Payment proof upload validation
- Private Storage access
- Admin-only payment verification
- Rejected proof and resubmission
- Revenue calculations
- Booking cancellation

Preserve existing tests and add relevant tests using the project's existing testing tools.

Run the build and relevant tests after each phase. Report actual results and explain anything that could not be tested.

## 11. Implementation Order

Build in this order:

Phase 1: Inspect the project and report the architecture and gaps.

Phase 2: Establish the design system and implement the public pages.

Phase 3: Implement authentication and customer/admin route protection.

Phase 4: Implement database rules and reliable court booking.

Phase 5: Implement customer dashboard and booking management.

Phase 6: Implement private payment-proof uploads and admin verification.

Phase 7: Implement admin management, court closures, settings, and reports.

Phase 8: Test the application, fix bugs, and document setup.

Keep each phase focused. Do not attempt a massive rewrite in one step.

After each phase, briefly report:
- What was implemented
- Files changed
- Tests and results
- Any required setup
- Remaining issues

## Final Instruction

Build a complete, usable, secure, responsive Pickleball Court Booking Website for a facility with two courts at ₱250 per hour.

Prioritize working functionality, reliable booking availability, secure payment-proof handling, and a polished user experience.

Follow the existing project architecture and preserve working code. Start by inspecting the project and reporting your plan before making major changes. Keep explanations concise to minimize token usage.