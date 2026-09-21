-- PayMind Health MVP v0.4
-- Supabase/PostgreSQL schema scaffold.
-- Run this in a new Supabase project's SQL Editor.
-- This is an architecture scaffold; verify policies and business rules before using with real hospital data.

create extension if not exists "pgcrypto";

create table if not exists public.hospitals (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  country text,
  currency text not null default 'ZMW',
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'finance_manager'
    check (role in ('admin','finance_manager','finance_officer','claims_officer','auditor','viewer')),
  created_at timestamptz not null default now()
);

create table if not exists public.hospital_members (
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'finance_manager'
    check (role in ('admin','finance_manager','finance_officer','claims_officer','auditor','viewer')),
  created_at timestamptz not null default now(),
  primary key (hospital_id, user_id)
);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  invoice_ref text not null,
  invoice_date date not null,
  amount numeric(14,2) not null check (amount >= 0),
  payer text not null,
  department text,
  status text not null default 'open'
    check (status in ('open','part_paid','paid','void')),
  created_at timestamptz not null default now(),
  unique (hospital_id, invoice_ref)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  payment_ref text,
  invoice_ref text,
  payment_date date not null,
  amount numeric(14,2) not null check (amount >= 0),
  payer text,
  payment_method text,
  bank_reference text,
  created_at timestamptz not null default now()
);

create table if not exists public.claims (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  claim_ref text not null,
  invoice_ref text,
  payer text not null,
  submitted_date date not null,
  amount numeric(14,2) not null check (amount >= 0),
  status text not null default 'submitted'
    check (status in ('draft','submitted','queried','approved','part_paid','paid','rejected')),
  notes text,
  created_at timestamptz not null default now(),
  unique (hospital_id, claim_ref)
);

create table if not exists public.exceptions (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  exception_ref text not null,
  exception_type text not null,
  payer text,
  exposure_amount numeric(14,2) not null default 0,
  priority text not null default 'medium'
    check (priority in ('low','medium','high')),
  reason text not null,
  suggested_action text not null,
  status text not null default 'open'
    check (status in ('open','in_review','resolved')),
  owner_id uuid references auth.users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.exception_actions (
  id uuid primary key default gen_random_uuid(),
  exception_id uuid not null references public.exceptions(id) on delete cascade,
  action_text text not null,
  status text not null default 'open'
    check (status in ('open','in_progress','complete')),
  owner_id uuid references auth.users(id),
  due_date date,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  user_id uuid references auth.users(id),
  event_type text not null,
  entity_type text,
  entity_id uuid,
  reference_text text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_invoices_hospital_date on public.invoices(hospital_id, invoice_date);
create index if not exists idx_payments_hospital_date on public.payments(hospital_id, payment_date);
create index if not exists idx_claims_hospital_date on public.claims(hospital_id, submitted_date);
create index if not exists idx_exceptions_hospital_status on public.exceptions(hospital_id, status);
create index if not exists idx_audit_hospital_created on public.audit_logs(hospital_id, created_at desc);

-- Basic row-level security setup.
alter table public.hospitals enable row level security;
alter table public.profiles enable row level security;
alter table public.hospital_members enable row level security;
alter table public.invoices enable row level security;
alter table public.payments enable row level security;
alter table public.claims enable row level security;
alter table public.exceptions enable row level security;
alter table public.exception_actions enable row level security;
alter table public.audit_logs enable row level security;

-- Helper function: determine whether current user belongs to a hospital.
create or replace function public.user_in_hospital(target_hospital uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.hospital_members hm
    where hm.hospital_id = target_hospital
      and hm.user_id = auth.uid()
  );
$$;

-- Read access for members. Writes should be restricted further by role in production.
drop policy if exists "hospital members can read hospital" on public.hospitals;
create policy "hospital members can read hospital" on public.hospitals
for select using (public.user_in_hospital(id));

drop policy if exists "members can read own membership" on public.hospital_members;
create policy "members can read own membership" on public.hospital_members
for select using (user_id = auth.uid());

drop policy if exists "members can read invoices" on public.invoices;
create policy "members can read invoices" on public.invoices
for select using (public.user_in_hospital(hospital_id));

drop policy if exists "members can read payments" on public.payments;
create policy "members can read payments" on public.payments
for select using (public.user_in_hospital(hospital_id));

drop policy if exists "members can read claims" on public.claims;
create policy "members can read claims" on public.claims
for select using (public.user_in_hospital(hospital_id));

drop policy if exists "members can read exceptions" on public.exceptions;
create policy "members can read exceptions" on public.exceptions
for select using (public.user_in_hospital(hospital_id));

drop policy if exists "members can read exception actions" on public.exception_actions;
create policy "members can read exception actions" on public.exception_actions
for select using (
  exists (
    select 1
    from public.exceptions e
    where e.id = exception_actions.exception_id
      and public.user_in_hospital(e.hospital_id)
  )
);

drop policy if exists "members can read audit logs" on public.audit_logs;
create policy "members can read audit logs" on public.audit_logs
for select using (public.user_in_hospital(hospital_id));

-- IMPORTANT:
-- Add explicit insert/update/delete policies tied to hospital_members.role before
-- connecting real data. Do not rely on broad client-side controls.
