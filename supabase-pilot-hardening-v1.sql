-- PayMind Health v2.1.58
-- Pilot-readiness + security-hardening migration.
-- Run AFTER the original supabase-schema.sql in the Supabase SQL Editor.
-- Safe to re-run: objects/policies are created idempotently where practical.
--
-- Goals:
-- 1) Bring the database contract in line with v2.1.58.
-- 2) Enforce tenant isolation and role-based writes with RLS.
-- 3) Make recovery receipts append-only and prevent over-recovery.
-- 4) Enforce one active recovery action per exception.
-- 5) Keep recovery evidence in a private, tenant-scoped Storage bucket.
-- 6) Keep audit records user-bound and append-only from the client.

begin;

-- ============================================================
-- 1. Current v2.1.58 recovery data contract
-- ============================================================

alter table public.exceptions
  add column if not exists recovery_status text not null default 'not_started',
  add column if not exists recovery_amount numeric(14,2) not null default 0,
  add column if not exists recovery_date date,
  add column if not exists recovery_started_at timestamptz,
  add column if not exists recovery_reference text,
  add column if not exists recovery_note text;

update public.exceptions
set recovery_amount = greatest(least(coalesce(recovery_amount,0), exposure_amount),0),
    recovery_status = case
      when greatest(least(coalesce(recovery_amount,0), exposure_amount),0) >= exposure_amount
           and exposure_amount > 0 then 'fully_recovered'
      when greatest(least(coalesce(recovery_amount,0), exposure_amount),0) > 0 then 'partially_recovered'
      else 'not_started'
    end
where true;

alter table public.exceptions
  drop constraint if exists exceptions_recovery_status_check,
  drop constraint if exists exceptions_recovery_amount_check,
  drop constraint if exists exceptions_recovery_fully_recovered_check;

alter table public.exceptions
  add constraint exceptions_recovery_status_check
    check (recovery_status in ('not_started','partially_recovered','fully_recovered')),
  add constraint exceptions_recovery_amount_check
    check (recovery_amount >= 0 and recovery_amount <= exposure_amount),
  add constraint exceptions_recovery_fully_recovered_check
    check (recovery_status <> 'fully_recovered' or recovery_amount = exposure_amount);

do $paymind$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'exceptions_id_hospital_unique'
      and conrelid = 'public.exceptions'::regclass
  ) then
    alter table public.exceptions
      add constraint exceptions_id_hospital_unique unique (id,hospital_id);
  end if;
end $;

create table if not exists public.recovery_transactions (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  exception_id uuid not null,
  amount numeric(14,2) not null check (amount > 0),
  recovery_date date not null default current_date,
  recovery_reference text,
  note text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

do $paymind$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'recovery_transactions_id_hospital_unique'
      and conrelid = 'public.recovery_transactions'::regclass
  ) then
    alter table public.recovery_transactions
      add constraint recovery_transactions_id_hospital_unique unique (id,hospital_id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'recovery_transactions_exception_hospital_fk'
      and conrelid = 'public.recovery_transactions'::regclass
  ) then
    alter table public.recovery_transactions
      add constraint recovery_transactions_exception_hospital_fk
      foreign key (exception_id,hospital_id)
      references public.exceptions(id,hospital_id)
      on delete cascade;
  end if;
end $;

alter table public.recovery_transactions
  drop constraint if exists recovery_transactions_amount_check;

alter table public.recovery_transactions
  add constraint recovery_transactions_amount_check check (amount > 0);

create table if not exists public.recovery_actions (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  exception_id uuid not null,
  action_text text not null,
  status text not null default 'planned'
    check (status in ('planned','in_progress','completed','cancelled')),
  owner_id uuid references auth.users(id),
  due_date date,
  completed_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $paymind$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'recovery_actions_id_hospital_unique'
      and conrelid = 'public.recovery_actions'::regclass
  ) then
    alter table public.recovery_actions
      add constraint recovery_actions_id_hospital_unique unique (id,hospital_id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'recovery_actions_exception_hospital_fk'
      and conrelid = 'public.recovery_actions'::regclass
  ) then
    alter table public.recovery_actions
      add constraint recovery_actions_exception_hospital_fk
      foreign key (exception_id,hospital_id)
      references public.exceptions(id,hospital_id)
      on delete cascade;
  end if;
end $;

alter table public.recovery_actions
  drop constraint if exists recovery_actions_status_check;

alter table public.recovery_actions
  add constraint recovery_actions_status_check
  check (status in ('planned','in_progress','completed','cancelled'));

create table if not exists public.recovery_evidence (
  id uuid primary key default gen_random_uuid(),
  hospital_id uuid not null references public.hospitals(id) on delete cascade,
  exception_id uuid not null,
  recovery_transaction_id uuid references public.recovery_transactions(id),
  evidence_type text not null,
  file_name text not null,
  storage_path text not null,
  mime_type text,
  file_size bigint,
  description text,
  uploaded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

do $paymind$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'recovery_evidence_id_hospital_unique'
      and conrelid = 'public.recovery_evidence'::regclass
  ) then
    alter table public.recovery_evidence
      add constraint recovery_evidence_id_hospital_unique unique (id,hospital_id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'recovery_evidence_exception_hospital_fk'
      and conrelid = 'public.recovery_evidence'::regclass
  ) then
    alter table public.recovery_evidence
      add constraint recovery_evidence_exception_hospital_fk
      foreign key (exception_id,hospital_id)
      references public.exceptions(id,hospital_id)
      on delete cascade;
  end if;
end $;

alter table public.recovery_evidence
  drop constraint if exists recovery_evidence_evidence_type_check,
  drop constraint if exists recovery_evidence_file_size_check,
  drop constraint if exists recovery_evidence_storage_path_check;

alter table public.recovery_evidence
  add constraint recovery_evidence_evidence_type_check
    check (evidence_type in (
      'remittance_advice',
      'bank_confirmation',
      'payer_correspondence',
      'receipt',
      'credit_note',
      'other'
    )),
  add constraint recovery_evidence_file_size_check
    check (file_size is null or (file_size >= 0 and file_size <= 10485760)),
  add constraint recovery_evidence_storage_path_check
    check (storage_path like hospital_id::text || '/' || exception_id::text || '/%');

create index if not exists idx_recovery_transactions_hospital_date
  on public.recovery_transactions(hospital_id,recovery_date desc,created_at desc);

create index if not exists idx_recovery_transactions_exception
  on public.recovery_transactions(exception_id,created_at desc);

create index if not exists idx_recovery_actions_hospital_due
  on public.recovery_actions(hospital_id,due_date,status);

create index if not exists idx_recovery_actions_exception
  on public.recovery_actions(exception_id,created_at desc);

create index if not exists idx_recovery_evidence_hospital_created
  on public.recovery_evidence(hospital_id,created_at desc);

create index if not exists idx_recovery_evidence_exception
  on public.recovery_evidence(exception_id,created_at desc);

-- One active recovery action per exception.
create unique index if not exists uq_one_active_recovery_action_per_exception
  on public.recovery_actions(exception_id)
  where status not in ('completed','cancelled');

-- v2.1.58 expects RLS on these tables.
alter table public.recovery_transactions enable row level security;
alter table public.recovery_actions enable row level security;
alter table public.recovery_evidence enable row level security;

-- ============================================================
-- 2. Role helper used by RLS
-- ============================================================

create or replace function public.user_has_hospital_role(
  target_hospital uuid,
  allowed_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = public
as $paymind$
  select exists (
    select 1
    from public.hospital_members hm
    where hm.hospital_id = target_hospital
      and hm.user_id = auth.uid()
      and hm.role = any(allowed_roles)
  );
$paymind$;

revoke all on function public.user_has_hospital_role(uuid,text[]) from public;
grant execute on function public.user_has_hospital_role(uuid,text[]) to authenticated;

-- ============================================================
-- 3. Tenant binding and recovery integrity controls
-- ============================================================

create or replace function public.prevent_hospital_id_change()
returns trigger
language plpgsql
as $paymind$
begin
  if new.hospital_id is distinct from old.hospital_id then
    raise exception 'hospital_id is immutable';
  end if;
  return new;
end;
$paymind$;

drop trigger if exists trg_invoices_hospital_immutable on public.invoices;
create trigger trg_invoices_hospital_immutable
before update on public.invoices
for each row execute function public.prevent_hospital_id_change();

drop trigger if exists trg_payments_hospital_immutable on public.payments;
create trigger trg_payments_hospital_immutable
before update on public.payments
for each row execute function public.prevent_hospital_id_change();

drop trigger if exists trg_claims_hospital_immutable on public.claims;
create trigger trg_claims_hospital_immutable
before update on public.claims
for each row execute function public.prevent_hospital_id_change();

drop trigger if exists trg_exceptions_hospital_immutable on public.exceptions;
create trigger trg_exceptions_hospital_immutable
before update on public.exceptions
for each row execute function public.prevent_hospital_id_change();

drop trigger if exists trg_recovery_transactions_hospital_immutable on public.recovery_transactions;
create trigger trg_recovery_transactions_hospital_immutable
before update on public.recovery_transactions
for each row execute function public.prevent_hospital_id_change();

drop trigger if exists trg_recovery_actions_hospital_immutable on public.recovery_actions;
create trigger trg_recovery_actions_hospital_immutable
before update on public.recovery_actions
for each row execute function public.prevent_hospital_id_change();

drop trigger if exists trg_recovery_evidence_hospital_immutable on public.recovery_evidence;
create trigger trg_recovery_evidence_hospital_immutable
before update on public.recovery_evidence
for each row execute function public.prevent_hospital_id_change();

create or replace function public.prevent_exception_action_identity_change()
returns trigger
language plpgsql
as $paymind$
begin
  if new.exception_id is distinct from old.exception_id then
    raise exception 'exception_id is immutable for exception actions';
  end if;
  return new;
end;
$paymind$;

drop trigger if exists trg_exception_action_identity_immutable on public.exception_actions;
create trigger trg_exception_action_identity_immutable
before update on public.exception_actions
for each row execute function public.prevent_exception_action_identity_change();

create or replace function public.prevent_recovery_action_identity_change()
returns trigger
language plpgsql
as $paymind$
begin
  if new.exception_id is distinct from old.exception_id then
    raise exception 'exception_id is immutable for recovery actions';
  end if;
  return new;
end;
$paymind$;

drop trigger if exists trg_recovery_action_identity_immutable on public.recovery_actions;
create trigger trg_recovery_action_identity_immutable
before update on public.recovery_actions
for each row execute function public.prevent_recovery_action_identity_change();

create or replace function public.validate_recovery_evidence()
returns trigger
language plpgsql
as $paymind$
declare
  tx_hospital uuid;
  tx_exception uuid;
begin
  if new.recovery_transaction_id is not null then
    select rt.hospital_id, rt.exception_id
      into tx_hospital, tx_exception
    from public.recovery_transactions rt
    where rt.id = new.recovery_transaction_id;

    if tx_hospital is null then
      raise exception 'Linked recovery transaction does not exist';
    end if;

    if tx_hospital is distinct from new.hospital_id
       or tx_exception is distinct from new.exception_id then
      raise exception 'Evidence must reference a recovery transaction in the same hospital and exception';
    end if;
  end if;

  return new;
end;
$paymind$;

drop trigger if exists trg_validate_recovery_evidence on public.recovery_evidence;
create trigger trg_validate_recovery_evidence
before insert on public.recovery_evidence
for each row execute function public.validate_recovery_evidence();

create or replace function public.validate_recovery_transaction()
returns trigger
language plpgsql
as $paymind$
declare
  exposure numeric(14,2);
  current_total numeric(14,2);
begin
  select e.exposure_amount
    into exposure
  from public.exceptions e
  where e.id = new.exception_id
    and e.hospital_id = new.hospital_id
  for update;

  if exposure is null then
    raise exception 'Exception does not exist in the supplied hospital';
  end if;

  select coalesce(sum(rt.amount),0)
    into current_total
  from public.recovery_transactions rt
  where rt.exception_id = new.exception_id;

  if current_total + new.amount > exposure then
    raise exception 'Recovery receipt exceeds outstanding exposure';
  end if;

  return new;
end;
$paymind$;

drop trigger if exists trg_validate_recovery_transaction on public.recovery_transactions;
create trigger trg_validate_recovery_transaction
before insert on public.recovery_transactions
for each row execute function public.validate_recovery_transaction();

create or replace function public.sync_exception_recovery_from_transaction()
returns trigger
language plpgsql
as $paymind$
declare
  total_recovered numeric(14,2);
  exposure numeric(14,2);
  latest_date date;
  latest_reference text;
  latest_note text;
begin
  select e.exposure_amount
    into exposure
  from public.exceptions e
  where e.id = new.exception_id
    and e.hospital_id = new.hospital_id
  for update;

  select coalesce(sum(rt.amount),0)
    into total_recovered
  from public.recovery_transactions rt
  where rt.exception_id = new.exception_id;

  select rt.recovery_date, rt.recovery_reference, rt.note
    into latest_date, latest_reference, latest_note
  from public.recovery_transactions rt
  where rt.exception_id = new.exception_id
  order by rt.recovery_date desc, rt.created_at desc
  limit 1;

  update public.exceptions
  set recovery_amount = least(greatest(total_recovered,0),greatest(exposure,0)),
      recovery_status = case
        when exposure > 0 and total_recovered >= exposure then 'fully_recovered'
        when total_recovered > 0 then 'partially_recovered'
        else 'not_started'
      end,
      recovery_date = latest_date,
      recovery_reference = latest_reference,
      recovery_note = latest_note,
      recovery_started_at = coalesce(recovery_started_at,new.created_at),
      updated_at = now()
  where id = new.exception_id
    and hospital_id = new.hospital_id;

  return new;
end;
$paymind$;

drop trigger if exists trg_sync_exception_recovery on public.recovery_transactions;
create trigger trg_sync_exception_recovery
after insert on public.recovery_transactions
for each row execute function public.sync_exception_recovery_from_transaction();

-- ============================================================
-- 4. Write policies: operational data
-- ============================================================

drop policy if exists "members can insert invoices" on public.invoices;
create policy "members can insert invoices"
on public.invoices for insert to authenticated
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "finance users can update invoices" on public.invoices;
create policy "finance users can update invoices"
on public.invoices for update to authenticated
using (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
)
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "members can insert payments" on public.payments;
create policy "members can insert payments"
on public.payments for insert to authenticated
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "finance users can update payments" on public.payments;
create policy "finance users can update payments"
on public.payments for update to authenticated
using (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
)
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "claims users can insert claims" on public.claims;
create policy "claims users can insert claims"
on public.claims for insert to authenticated
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer','claims_officer']::text[]
  )
);

drop policy if exists "claims users can update claims" on public.claims;
create policy "claims users can update claims"
on public.claims for update to authenticated
using (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer','claims_officer']::text[]
  )
)
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer','claims_officer']::text[]
  )
);

drop policy if exists "finance users can insert exceptions" on public.exceptions;
create policy "finance users can insert exceptions"
on public.exceptions for insert to authenticated
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "finance users can update exceptions" on public.exceptions;
create policy "finance users can update exceptions"
on public.exceptions for update to authenticated
using (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
)
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "finance users can insert exception actions" on public.exception_actions;
create policy "finance users can insert exception actions"
on public.exception_actions for insert to authenticated
with check (
  exists (
    select 1
    from public.exceptions e
    where e.id = exception_actions.exception_id
      and public.user_has_hospital_role(
        e.hospital_id,
        array['admin','finance_manager','finance_officer']::text[]
      )
  )
);

drop policy if exists "finance users can update exception actions" on public.exception_actions;
create policy "finance users can update exception actions"
on public.exception_actions for update to authenticated
using (
  exists (
    select 1
    from public.exceptions e
    where e.id = exception_actions.exception_id
      and public.user_has_hospital_role(
        e.hospital_id,
        array['admin','finance_manager','finance_officer']::text[]
      )
  )
)
with check (
  exists (
    select 1
    from public.exceptions e
    where e.id = exception_actions.exception_id
      and public.user_has_hospital_role(
        e.hospital_id,
        array['admin','finance_manager','finance_officer']::text[]
      )
  )
);

-- ============================================================
-- 5. Recovery policies: members can read, finance users can write
-- ============================================================

drop policy if exists "members can read recovery transactions" on public.recovery_transactions;
create policy "members can read recovery transactions"
on public.recovery_transactions for select to authenticated
using (public.user_in_hospital(hospital_id));

drop policy if exists "finance users can insert recovery transactions" on public.recovery_transactions;
create policy "finance users can insert recovery transactions"
on public.recovery_transactions for insert to authenticated
with check (
  created_by = auth.uid()
  and public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

-- Deliberately no UPDATE/DELETE policy: the cash ledger is append-only from the client.

drop policy if exists "members can read recovery actions" on public.recovery_actions;
create policy "members can read recovery actions"
on public.recovery_actions for select to authenticated
using (public.user_in_hospital(hospital_id));

drop policy if exists "finance users can insert recovery actions" on public.recovery_actions;
create policy "finance users can insert recovery actions"
on public.recovery_actions for insert to authenticated
with check (
  created_by = auth.uid()
  and (owner_id is null or owner_id = auth.uid())
  and public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

drop policy if exists "finance users can update recovery actions" on public.recovery_actions;
create policy "finance users can update recovery actions"
on public.recovery_actions for update to authenticated
using (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
)
with check (
  public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
  and (owner_id is null or owner_id = auth.uid())
);

drop policy if exists "members can read recovery evidence" on public.recovery_evidence;
create policy "members can read recovery evidence"
on public.recovery_evidence for select to authenticated
using (public.user_in_hospital(hospital_id));

drop policy if exists "finance users can insert recovery evidence" on public.recovery_evidence;
create policy "finance users can insert recovery evidence"
on public.recovery_evidence for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and public.user_has_hospital_role(
    hospital_id,
    array['admin','finance_manager','finance_officer']::text[]
  )
);

-- Deliberately no UPDATE/DELETE policy: uploaded evidence is immutable from the client.

-- ============================================================
-- 6. Audit log: readable by members, append-only and user-bound
-- ============================================================

drop policy if exists "members can insert audit logs" on public.audit_logs;
create policy "members can insert audit logs"
on public.audit_logs for insert to authenticated
with check (
  user_id = auth.uid()
  and public.user_in_hospital(hospital_id)
);

-- Existing select policy remains. No UPDATE/DELETE policy is created.

-- ============================================================
-- 7. Private recovery-evidence storage bucket
-- ============================================================

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values (
  'paymind-recovery-evidence',
  'paymind-recovery-evidence',
  false,
  10485760,
  array['application/pdf','image/png','image/jpeg','text/plain']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "PayMind evidence members can read" on storage.objects;
create policy "PayMind evidence members can read"
on storage.objects for select to authenticated
using (
  bucket_id = 'paymind-recovery-evidence'
  and exists (
    select 1
    from public.hospital_members hm
    where hm.hospital_id::text = (storage.foldername(name))[1]
      and hm.user_id = auth.uid()
  )
);

drop policy if exists "PayMind evidence finance users can upload" on storage.objects;
create policy "PayMind evidence finance users can upload"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'paymind-recovery-evidence'
  and exists (
    select 1
    from public.exceptions e
    where e.hospital_id::text = (storage.foldername(name))[1]
      and e.id::text = (storage.foldername(name))[2]
      and public.user_has_hospital_role(
        e.hospital_id,
        array['admin','finance_manager','finance_officer']::text[]
      )
  )
);

-- Deliberately no UPDATE/DELETE storage policy for pilot client users.

commit;
