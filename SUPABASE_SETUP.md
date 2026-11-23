# LabLink Supabase Backend Integration Guide

LabLink features an enterprise-grade hybrid storage architecture:
1. **Offline & Deterministic Mode (Default)**: Uses client-side IndexedDB/LocalStorage with seeded PRNG (Mulberry32) for zero-downtime, credential-free demonstration.
2. **Cloud PostgreSQL Mode (Supabase)**: Connects to a live Supabase PostgreSQL backend with full relational schema, Row Level Security (RLS), and real-time synchronization.

---

## Architecture Overview

```
                      +-----------------------------+
                      |   Zustand App Store         |
                      |   (Indexed O(1) Maps)       |
                      +--------------+--------------+
                                     |
               +---------------------+---------------------+
               |                                           |
               v (Synchronous / Optimistic)                v (Asynchronous / Non-blocking)
   +-----------------------+                   +-----------------------+
   |  LocalStorage Layer   |                   |  SupabaseService      |
   |  (Zod validated)      |                   |  (PostgreSQL Client)  |
   +-----------------------+                   +-----------+-----------+
                                                           |
                                                           v
                                               +-----------------------+
                                               |  Supabase Cloud DB    |
                                               |  (Postgres + RLS)     |
                                               +-----------------------+
```

---

## 1. Fast Setup Instructions

### Step 1: Create a Supabase Project
1. Go to [https://supabase.com](https://supabase.com) and create a free project.
2. Note your **Project URL** and **anon public key** from `Settings` -> `API`.

### Step 2: Run the SQL Migration
1. In the Supabase Dashboard, open the **SQL Editor**.
2. Open `supabase/migrations/20261123_init.sql` from this repository.
3. Paste the entire SQL script and click **Run**.
   - This creates 12 relational tables: `departments`, `laboratories`, `equipment`, `users`, `projects`, `booking_requests`, `bookings`, `conflicts`, `maintenance_records`, `notifications`, `audit_logs`, and `engine_weights`.
   - It also enables Row Level Security (RLS) with permissive public policies suited for the demo persona switcher.

### Step 3: Configure Environment Variables
Create or edit your `.env` file in the project root:

```env
VITE_SUPABASE_URL=https://your-project-id.supabase.co
VITE_SUPABASE_ANON_KEY=your-actual-anon-key-here
```

### Step 4: Seed Data into Supabase
Run the dev server:
```bash
npm run dev
```

Open the app:
1. Switch to the **Campus Admin** persona in the top navigation bar.
2. Navigate to **Admin Portal** -> **Database & Cloud Backend** tab.
3. Click **"Push Seed Data to Supabase"**.
4. All 128 equipment units, 12 labs, 6 departments, 46 users, and active booking conflict scenarios will be written directly into your Supabase database!

---

## 2. Table Schema Reference

| Table | Primary Key | Description |
|---|---|---|
| `departments` | `id` (text) | Academic departments (CSE, Mech, Biotech, etc.) |
| `laboratories` | `id` (text) | Departmental facilities with operating hours and safety tiers |
| `equipment` | `id` (text) | Specialized instruments with specs, condition, and prerequisites |
| `users` | `id` (text) | Student, Faculty, Lab Manager, and Admin personas |
| `projects` | `id` (text) | Student research and capstone projects |
| `booking_requests` | `id` (text) | Raw allocation requests submitted by students |
| `bookings` | `id` (text) | Confirmed reservation slots scheduled on equipment |
| `conflicts` | `id` (text) | Detected contention cases (including Hero Robotics/AI scenario) |
| `maintenance_records` | `id` (text) | Calibration, repair, and routine maintenance logs |
| `notifications` | `id` (text) | User inbox alerts for approvals and cancellations |
| `audit_logs` | `id` (text) | Tamper-evident ledger of all administrative and engine operations |
| `engine_weights` | `id` (text) | Configurable multi-criteria fair allocation weights |

---

## 3. Resilience & Graceful Fallback

- If `VITE_SUPABASE_URL` is omitted, LabLink functions seamlessly in local mode with zero console errors.
- If Supabase encounters network timeouts or rate limits, LabLink automatically falls back to local storage and alerts the user via the top bar badge: `[DB Offline (Fallback)]`.
