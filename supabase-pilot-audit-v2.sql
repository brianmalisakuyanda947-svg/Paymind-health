-- PayMind Health v2.1.58 — authoritative audit trail hardening
-- Apply AFTER supabase-pilot-hardening-v1.sql.
--
-- Client-originated activity remains available for user workflow notes, but is
-- explicitly tagged source='client'. Database-trigger rows are tagged
-- source='database_trigger' and cannot be forged through the client INSERT RLS
-- policy. Do not rely on client-originated events as sole evidence of a financial
-- state change.

begin;

alter table public.audit_logs
  add column if not exists source text not null default 'client';

update public.audit_logs
set source = 'client'
where source is null or source not in ('client','database_trigger');

alter table public.audit_logs
  drop constraint if exists audit_logs_source_check;

alter table public.audit_logs
  add constraint audit_logs_source_check
  check (source in ('client','database_trigger'));

-- Authenticated users may append only client-tagged activity for their own user
-- and hospital. They cannot forge a database-trigger event source or db_* event.
drop policy if exists "members can insert audit logs" on public.audit_logs;
create policy "members can insert audit logs"
on public.audit_logs
for insert
to authenticated
with check (
  source = 'client'
  and event_type !~ '^db_'
  and user_id = auth.uid()
  and public.user_in_hospital(hospital_id)
);

create or replace function public.paymind_audit_core_row_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $paymind$
declare
  old_doc jsonb := '{}'::jsonb;
  new_doc jsonb := '{}'::jsonb;
  row_doc jsonb := '{}'::jsonb;
  changed_fields text[] := array[]::text[];
  before_safe jsonb := '{}'::jsonb;
  after_safe jsonb := '{}'::jsonb;
  hospital_text text;
  ref_text text;
  entity_uuid uuid;
  actor_uuid uuid;
  exception_uuid uuid;
begin
  if TG_OP <> 'INSERT' then
    old_doc := to_jsonb(OLD);
  end if;
  if TG_OP <> 'DELETE' then
    new_doc := to_jsonb(NEW);
  end if;

  row_doc := case when TG_OP = 'DELETE' then old_doc else new_doc end;
  hospital_text := coalesce(new_doc->>'hospital_id', old_doc->>'hospital_id');

  if hospital_text is null then
    raise exception 'Audit trigger could not determine hospital_id for %.%', TG_TABLE_SCHEMA, TG_TABLE_NAME;
  end if;

  entity_uuid := nullif(coalesce(new_doc->>'id', old_doc->>'id'), '')::uuid;
  actor_uuid := auth.uid();

  select coalesce(array_agg(k order by k), array[]::text[])
  into changed_fields
  from (
    select key as k from jsonb_object_keys(old_doc) as old_keys(key)
    union
    select key as k from jsonb_object_keys(new_doc) as new_keys(key)
  ) keys
  where old_doc->k is distinct from new_doc->k;

  before_safe := jsonb_strip_nulls(jsonb_build_object(
    'status', old_doc->>'status',
    'recovery_status', old_doc->>'recovery_status',
    'amount', old_doc->>'amount',
    'exposure_amount', old_doc->>'exposure_amount',
    'recovery_amount', old_doc->>'recovery_amount',
    'invoice_ref', old_doc->>'invoice_ref',
    'payment_ref', old_doc->>'payment_ref',
    'claim_ref', old_doc->>'claim_ref',
    'exception_ref', old_doc->>'exception_ref',
    'owner_id', old_doc->>'owner_id',
    'due_date', old_doc->>'due_date',
    'recovery_reference', old_doc->>'recovery_reference',
    'evidence_type', old_doc->>'evidence_type'
  ));

  after_safe := jsonb_strip_nulls(jsonb_build_object(
    'status', new_doc->>'status',
    'recovery_status', new_doc->>'recovery_status',
    'amount', new_doc->>'amount',
    'exposure_amount', new_doc->>'exposure_amount',
    'recovery_amount', new_doc->>'recovery_amount',
    'invoice_ref', new_doc->>'invoice_ref',
    'payment_ref', new_doc->>'payment_ref',
    'claim_ref', new_doc->>'claim_ref',
    'exception_ref', new_doc->>'exception_ref',
    'owner_id', new_doc->>'owner_id',
    'due_date', new_doc->>'due_date',
    'recovery_reference', new_doc->>'recovery_reference',
    'evidence_type', new_doc->>'evidence_type'
  ));

  ref_text := coalesce(
    new_doc->>'exception_ref', old_doc->>'exception_ref',
    new_doc->>'invoice_ref', old_doc->>'invoice_ref',
    new_doc->>'payment_ref', old_doc->>'payment_ref',
    new_doc->>'claim_ref', old_doc->>'claim_ref'
  );

  if ref_text is null then
    exception_uuid := nullif(coalesce(new_doc->>'exception_id', old_doc->>'exception_id'), '')::uuid;
    if exception_uuid is not null then
      select e.exception_ref
      into ref_text
      from public.exceptions e
      where e.id = exception_uuid;
    end if;
  end if;

  insert into public.audit_logs (
    hospital_id, user_id, event_type, entity_type, entity_id,
    reference_text, detail, source
  )
  values (
    hospital_text::uuid,
    actor_uuid,
    'db_' || TG_TABLE_NAME || '_' || lower(TG_OP),
    TG_TABLE_NAME,
    entity_uuid,
    coalesce(ref_text, entity_uuid::text),
    jsonb_build_object(
      'operation', TG_OP,
      'changed_fields', to_jsonb(changed_fields),
      'before', before_safe,
      'after', after_safe
    ),
    'database_trigger'
  );

  if TG_OP = 'DELETE' then
    return OLD;
  end if;
  return NEW;
end;
$paymind$;

-- These tables contain the primary financial/recovery state changes that must
-- have a server-generated audit event independent of browser JavaScript.
drop trigger if exists trg_paymind_audit_row_change on public.invoices;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.invoices
for each row execute function public.paymind_audit_core_row_change();

drop trigger if exists trg_paymind_audit_row_change on public.payments;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.payments
for each row execute function public.paymind_audit_core_row_change();

drop trigger if exists trg_paymind_audit_row_change on public.claims;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.claims
for each row execute function public.paymind_audit_core_row_change();

drop trigger if exists trg_paymind_audit_row_change on public.exceptions;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.exceptions
for each row execute function public.paymind_audit_core_row_change();

drop trigger if exists trg_paymind_audit_row_change on public.recovery_transactions;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.recovery_transactions
for each row execute function public.paymind_audit_core_row_change();

drop trigger if exists trg_paymind_audit_row_change on public.recovery_actions;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.recovery_actions
for each row execute function public.paymind_audit_core_row_change();

drop trigger if exists trg_paymind_audit_row_change on public.recovery_evidence;
create trigger trg_paymind_audit_row_change
after insert or update or delete on public.recovery_evidence
for each row execute function public.paymind_audit_core_row_change();

commit;

-- Read-only verification: seven core-table triggers should be enabled.
select
  c.relname as table_name,
  t.tgname as trigger_name,
  t.tgenabled = 'O' as enabled
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and t.tgname = 'trg_paymind_audit_row_change'
  and not t.tgisinternal
order by c.relname;
