import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined
export const supabase = url && key ? createClient(url, key) : null

export type Booking = {
  id: string; reference: string; user_id: string; court_id: number; booking_date: string
  start_hour: number; duration_hours: number; total_price: number; status: string
  payment_status: string; created_at: string; hold_expires_at?: string | null; profiles?: { full_name: string; email: string }
  payments?: { status: string; rejection_reason: string | null; submitted_at: string }[]
}
export const peso = (value: number) => `₱${Number(value).toLocaleString('en-PH')}`
export const hourLabel = (hour: number) => `${hour % 12 || 12}:00 ${hour < 12 ? 'AM' : 'PM'}`
