-- PayMind Health v2.1.58 — claim/invoice referential integrity v1
-- Review branch: pilot-claims-invoice-integrity-v1
--
-- Purpose:
-- 1. A claim may be a draft without an invoice.
-- 2. Any non-draft claim must have a non-empty invoice reference.
-- 3. Any supplied invoice reference must exist for the SAME hospital.
--
-- SAFETY:
-- This migration intentionally aborts before changing the schema when existing
-- claims contain orphaned/blank invoice references or non-draft claims lack a
-- reference. It does not silently repair, delete, or reclassify production data.
-- Reconcile affected records through an approved workflow first.
--
-- Run only after supabase-pilot-hardening-v1.sql and other required pilot
-- migrations, and only after reviewing the preflight result. Test on a restored
-- isolated database before considering any production deployment.

begin;

-- ============================================================
-- 1. Preflight: fail before DDL if existing data is inconsistent.
-- ============================================================

do $paymind_preflight$
declare
  v_orphaned_refs bigint;
  v_missing_refs bigint;
  v_blank_refs bigint;
begin
  select count(*)
    into v_orphaned_refs
  from public.claims c
  where c.invoice_ref is not null
    and not exists (
      select 1
      from public.invoices i
      where i.hospital_id = c.hospital_id
        and i.invoice_ref = c.invoice_ref
    );

  select count(*)
    into v_missing_refs
  from public.claims c
  where c.status <> 'draft'
    and nullif(btrim(c.invoice_ref), '') is null;

  select count(*)
    into v_blank_refs
  from public.claims c
  where c.invoice_ref is not null
    and nullif(btrim(c.invoice_ref), '') is null;

  if v_orphaned_refs > 0 or v_missing_refs > 0 or v_blank_refs > 0 then
    raise exception
      'Claims/invoice integrity migration aborted: orphaned invoice references=%, non-draft claims without invoice references=%, blank invoice references=%.',
      v_orphaned_refs, v_missing_refs, v_blank_refs
      using hint =
        'Inspect the affected synthetic/business records and reconcile them explicitly. This migration does not alter data automatically.';
  end if;
end;
$paymind_preflight$;

-- ============================================================
-- 2. Composite FK: invoice reference must belong to same hospital.
-- ============================================================

do $paymind_fk$
declare
  v_fk pg_constraint%rowtype;
  v_local_columns text[];
  v_referenced_columns text[];
begin
  select *
    into v_fk
  from pg_constraint
  where conrelid = 'public.claims'::regclass
    and conname = 'claims_hospital_invoice_fkey';

  if not found then
    alter table public.claims
      add constraint claims_hospital_invoice_fkey
      foreign key (hospital_id, invoice_ref)
      references public.invoices (hospital_id, invoice_ref)
      not valid;
  else
    if v_fk.contype <> 'f'
       or v_fk.confrelid <> 'public.invoices'::regclass
       or v_fk.confmatchtype <> 's'
       or v_fk.confdeltype <> 'a'
       or v_fk.confupdtype <> 'a'
       or v_fk.condeferrable then
      raise exception
        'Constraint claims_hospital_invoice_fkey already exists with an unexpected definition; review it manually.';
    end if;

    select array_agg(a.attname::text order by u.ordinality)
      into v_local_columns
    from unnest(v_fk.conkey) with ordinality as u(attnum, ordinality)
    join pg_attribute a
      on a.attrelid = v_fk.conrelid
     and a.attnum = u.attnum;

    select array_agg(a.attname::text order by u.ordinality)
      into v_referenced_columns
    from unnest(v_fk.confkey) with ordinality as u(attnum, ordinality)
    join pg_attribute a
      on a.attrelid = v_fk.confrelid
     and a.attnum = u.attnum;

    if v_local_columns is distinct from array['hospital_id', 'invoice_ref']::text[]
       or v_referenced_columns is distinct from array['hospital_id', 'invoice_ref']::text[] then
      raise exception
        'Constraint claims_hospital_invoice_fkey exists but does not cover the expected columns; review it manually.';
    end if;
  end if;
end;
$paymind_fk$;

-- ============================================================
-- 3. Drafts may omit invoices; non-drafts require a non-blank ref.
--    The FK above ensures that any supplied reference is valid.
-- ============================================================

do $paymind_check$
declare
  v_check pg_constraint%rowtype;
  v_definition text;
begin
  select *
    into v_check
  from pg_constraint
  where conrelid = 'public.claims'::regclass
    and conname = 'claims_invoice_required_outside_draft';

  if not found then
    alter table public.claims
      add constraint claims_invoice_required_outside_draft
      check (
        (status = 'draft'
          and (
            invoice_ref is null
            or nullif(btrim(invoice_ref), '') is not null
          )
        )
        or
        (status <> 'draft'
          and nullif(btrim(invoice_ref), '') is not null
        )
      )
      not valid;
  else
    if v_check.contype <> 'c' then
      raise exception
        'Constraint claims_invoice_required_outside_draft exists but is not a CHECK constraint.';
    end if;

    v_definition := lower(
      regexp_replace(pg_get_constraintdef(v_check.oid), '\s+', ' ', 'g')
    );

    if position('status = ''draft''' in v_definition) = 0
       or position('nullif(btrim(invoice_ref)' in v_definition) = 0 then
      raise exception
        'Constraint claims_invoice_required_outside_draft exists with an unexpected definition; review it manually.';
    end if;
  end if;
end;
$paymind_check$;

-- Validate existing records. Any error aborts and rolls back this transaction.
alter table public.claims
  validate constraint claims_hospital_invoice_fkey;

alter table public.claims
  validate constraint claims_invoice_required_outside_draft;

comment on constraint claims_hospital_invoice_fkey on public.claims is
  'A referenced invoice must exist in the same hospital workspace. Drafts may have a NULL invoice_ref.';

comment on constraint claims_invoice_required_outside_draft on public.claims is
  'Only draft claims may omit an invoice reference; all non-draft claims require a non-blank reference.';

commit;

-- Read-only verification.
select
  conname as constraint_name,
  convalidated as fully_validated,
  pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.claims'::regclass
  and conname in (
    'claims_hospital_invoice_fkey',
    'claims_invoice_required_outside_draft'
  )
order by conname;
