-- PayMind Health v2.1.58 — recovery status alignment
-- Run in Supabase SQL Editor after supabase-pilot-hardening-v1.sql.
-- This migration supports the UI's in-progress status and deliberately does
-- NOT enable "written_off"; audited write-off accounting is not implemented.
-- Safe to re-run. The transaction prevents a partial constraint change.

begin;

do $paymind$
begin
  if exists (
    select 1
    from public.exceptions
    where recovery_status not in (
      'not_started',
      'in_progress',
      'partially_recovered',
      'fully_recovered'
    )
  ) then
    raise exception
      'Unsupported recovery_status data exists. Review exceptions before applying this migration.';
  end if;
end;
$paymind$;

alter table public.exceptions
  drop constraint if exists exceptions_recovery_status_check;

alter table public.exceptions
  add constraint exceptions_recovery_status_check
  check (
    recovery_status in (
      'not_started',
      'in_progress',
      'partially_recovered',
      'fully_recovered'
    )
  );

comment on column public.exceptions.recovery_status is
  'Recovery workflow state. Write-off is intentionally excluded until a dedicated audited write-off workflow exists.';

commit;

-- Read-only verification: all current recovery states must be supported.
select
  recovery_status,
  count(*) as exception_count
from public.exceptions
group by recovery_status
order by recovery_status;
