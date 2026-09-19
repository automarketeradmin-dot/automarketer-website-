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
                                ('buy','sell','sell_auction','spotter','insurance','contract','other')),
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
  spotter_account_id          text, -- FK to spotter_accounts(id) added further down, once that table exists

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
-- 3. SPOTTER ACCOUNTS
-- ---------------------------------------------------------------------------
-- Mirrors registerSpotter()/loginSpotter() in app.js. The frontend currently
-- hashes passwords client-side with SHA-256 (Web Crypto) before this ever
-- reaches a server — that is NOT production-grade auth on its own. Once this
-- is real, migrate to Supabase Auth (email+password) instead of hand-rolled
-- password columns: create the user via supabase.auth.admin.createUser(),
-- store this table's other fields keyed by that auth user's id, and drop
-- password_hash entirely.
create table if not exists public.spotter_accounts (
  id                  text primary key,             -- matches the frontend's generated account id
  full_name           text not null,
  whatsapp            text not null,
  email               text not null unique,
  password_hash       text not null,                -- SHA-256 hex from the client — replace with Supabase Auth, see note above
  id_photo_path       text,                          -- Supabase Storage object path (spotter-verification bucket)
  verification_status text not null default 'Pending' check (verification_status in ('Pending','Verified','Rejected')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists spotter_accounts_email_idx on public.spotter_accounts (lower(email));

drop trigger if exists trg_spotter_accounts_updated_at on public.spotter_accounts;
create trigger trg_spotter_accounts_updated_at
  before update on public.spotter_accounts
  for each row execute function public.set_updated_at();

-- Now that spotter_accounts exists, link leads.spotter_account_id to it.
alter table public.leads
  add constraint leads_spotter_account_fk
  foreign key (spotter_account_id) references public.spotter_accounts(id);
create index if not exists leads_spotter_account_idx on public.leads (spotter_account_id);

-- ---------------------------------------------------------------------------
-- 4. STORAGE BUCKETS
-- ---------------------------------------------------------------------------
-- Run once (or via the Supabase dashboard → Storage → New bucket):
--   insert into storage.buckets (id, name, public) values
--     ('lead-uploads', 'lead-uploads', false),
--     ('spotter-verification', 'spotter-verification', false)
--   on conflict (id) do nothing;
-- Keep BOTH buckets PRIVATE — files must never be publicly listable.
-- spotter-verification holds ID documents specifically: treat it as more
-- sensitive than vehicle photos and restrict access even further once real
-- admin auth exists (e.g. only the 'automarketer_admin' role below).

-- ---------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
-- Leads and Spotter accounts both contain private personal information
-- (Section 34 of the brief — this now includes ID documents), so RLS must
-- stay ON with NO public read/write policies. All access happens through
-- Edge Functions using the service-role key (which bypasses RLS by design)
-- — never through a public anon-key client.
alter table public.leads             enable row level security;
alter table public.lead_notes        enable row level security;
alter table public.spotter_accounts  enable row level security;
-- No policies are created here on purpose: default-deny for the anon and
-- authenticated roles. Add narrowly-scoped policies only once a real admin
-- auth system (Section 22/35) exists, e.g.:
--
-- create policy "admins can read leads" on public.leads
--   for select using (auth.jwt() ->> 'role' = 'automarketer_admin');
--
-- A logged-in Spotter should only ever see their OWN leads — once Spotter
-- login moves to Supabase Auth, that policy looks like:
--
-- create policy "spotters read own leads" on public.leads
--   for select using (spotter_account_id = auth.uid()::text);
