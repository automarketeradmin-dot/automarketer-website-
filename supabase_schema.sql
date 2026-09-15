-- =============================================================================
-- AUTOMARKETER — Supabase schema
-- Run this in the Supabase SQL editor (or via `supabase db push`) on a real
-- Supabase project. This is not connected to anything yet — it's the schema
-- the frontend's normalized lead `record` (see buildNormalizedRecord in
-- app.js) is designed to map onto.
-- =============================================================================

create extension if not exists "pgcrypto"; -- for gen_random_uuid()

-- ---------------------------------------------------------------------------
-- 1. LEADS TABLE
-- ---------------------------------------------------------------------------
create table if not exists public.leads (
  id                          text primary key,               -- e.g. AM-BUY-0001 (matches frontend LEAD_PREFIXES)
  uuid                        uuid not null default gen_random_uuid(),
  lead_type                   text not null check (lead_type in
                                ('buy','sell','spotter','insurance','contract','other')),
  status                      text not null default 'New' check (status in
                                ('New','Contacted','In Progress','Matched','Completed','Closed','Cancelled')),
  priority                    text not null default 'Normal' check (priority in
                                ('Normal','High Priority','Urgent')),
  source                      text,                            -- Website / Instagram / TikTok / Referral / Spotter / Direct ...

  -- Submitter (buyer / seller / spotter themselves)
  name                        text,
  phone                       text,
  email                       text,
  location                    text,

  -- Spotter-specific: the actual buyer/seller the spotter is referring
  client_name                 text,
  client_phone                text,

  -- Vehicle
  vehicle_make                text,
  vehicle_model                text,
  vehicle_year                int,
  mileage                     int,
  transmission                text,
  vehicle_condition           text,
  budget                      numeric,
  asking_price                numeric,
  description                 text,

  -- Files (Supabase Storage object paths, not raw bytes)
  uploaded_files              jsonb not null default '[]'::jsonb,

  -- Consent / agreements
  agreement_accepted          boolean not null default false,
  agreement_version           text,
  agreement_accepted_at       timestamptz,
  consent_status              text not null default 'not_given' check (consent_status in ('given','not_given')),

  -- WhatsApp notification (set by the submit-lead Edge Function, not the client)
  whatsapp_notification_status text not null default 'pending' check (whatsapp_notification_status in
                                ('pending','sent','failed')),
  whatsapp_message_id         text,
  notification_error          text,

  -- Free-form original payload for anything not normalized above
  raw_data                    jsonb not null default '{}'::jsonb,

  is_duplicate                boolean not null default false,
  assigned_to                 text,

  submitted_at                timestamptz not null default now(),
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create index if not exists leads_type_idx      on public.leads (lead_type);
create index if not exists leads_status_idx    on public.leads (status);
create index if not exists leads_phone_idx     on public.leads (phone);
create index if not exists leads_created_idx   on public.leads (created_at desc);

-- Keep updated_at current on every row change
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_leads_updated_at on public.leads;
create trigger trg_leads_updated_at
  before update on public.leads
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. LEAD NOTES (internal admin notes — never shown to the customer)
-- ---------------------------------------------------------------------------
create table if not exists public.lead_notes (
  id          uuid primary key default gen_random_uuid(),
  lead_id     text not null references public.leads(id) on delete cascade,
  note        text not null,
  created_by  text,             -- admin user identifier, once real admin auth exists
  created_at  timestamptz not null default now()
);
create index if not exists lead_notes_lead_idx on public.lead_notes (lead_id);

-- ---------------------------------------------------------------------------
-- 3. STORAGE BUCKET for vehicle photos / documents
-- ---------------------------------------------------------------------------
-- Run once (or via the Supabase dashboard → Storage → New bucket):
--   insert into storage.buckets (id, name, public) values ('lead-uploads', 'lead-uploads', false)
--   on conflict (id) do nothing;
-- Keep this bucket PRIVATE — files must never be publicly listable. Access
-- them from the Edge Function using the service-role key, or generate
-- short-lived signed URLs for admin dashboard use only.

-- ---------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
-- Leads contain private customer information (Section 34 of the brief), so
-- RLS must stay ON with NO public read/write policies. All access happens
-- through the Edge Function using the service-role key (which bypasses RLS
-- by design) — never through a public anon-key client.
alter table public.leads      enable row level security;
alter table public.lead_notes enable row level security;
-- No policies are created here on purpose: default-deny for the anon and
-- authenticated roles. Add narrowly-scoped policies only once a real admin
-- auth system (Section 22/35) exists, e.g.:
--
-- create policy "admins can read leads" on public.leads
--   for select using (auth.jwt() ->> 'role' = 'automarketer_admin');
