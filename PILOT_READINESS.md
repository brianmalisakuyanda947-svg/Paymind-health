# PayMind Health — Pilot Readiness Checkpoint

Baseline: **v2.1.58**  
Branch: **pilot-hardening-v0.1**  
Date: 2026-10-04

## Completed before hardening

- End-to-end workflow baseline completed through exception, recovery and audit flows.
- v2.1.58 is the frozen product baseline for pilot hardening.
- Recovery controls include cumulative receipts, recovery actions, evidence and audit events.
- Fully-recovered receipt locking is present in v2.1.58.

## Findings from the v2.1.58 code audit

### 1. Database contract drift — HIGH

The repository's legacy `supabase-schema.sql` predates the current UI and does not define the v2.1.58 recovery tables/fields used by the application.

The current application expects:
- `exceptions.recovery_status`
- `exceptions.recovery_amount`
- `exceptions.recovery_date`
- `exceptions.recovery_started_at`
- `exceptions.recovery_reference`
- `exceptions.recovery_note`
- `recovery_transactions`
- `recovery_actions`
- `recovery_evidence`

**Action:** `supabase-pilot-hardening-v1.sql` adds the current data contract and security controls.

### 2. Recovery ledger integrity — HIGH

The browser previously enforced the no-over-recovery rule. The hardening migration now adds a database trigger that locks the exception row during receipt validation, prevents cumulative recovery from exceeding exposure, and synchronises exception-level recovery aggregates after a receipt is inserted.

The recovery transaction table is client-append-only: no update/delete policy is granted.

### 3. Recovery action concurrency — HIGH

The browser already allowed only one active recovery action per exception. The database now enforces the same rule with a partial unique index.

### 4. Tenant and role isolation — HIGH

The migration adds server-side RLS write policies based on `hospital_members.role`, plus immutable `hospital_id` controls on tenant-scoped records.

Default pilot write roles:
- Admin
- Finance Manager
- Finance Officer
- Claims Officer for claims

Viewer and Auditor remain read-only for operational tables.

### 5. Evidence privacy — HIGH

The recovery evidence bucket is private, capped at 10 MB per file, and restricted to the four MIME types already accepted by the UI:
PDF, PNG, JPEG and TXT.

Storage access is tenant-scoped. Client users receive no delete/update permission for evidence.

### 6. Evidence viewer bug — MEDIUM

The v2.1.58 UI had a click handler for `openRecoveryEvidence()` but no implementation in the file.

**Action completed:** the hardening branch adds a secure signed-URL viewer using a 120-second URL.

## Next pilot gate

Before merging `pilot-hardening-v0.1` to `main`:

1. Run `supabase-pilot-hardening-v1.sql` in the PayMind Supabase project.
2. Verify a finance user can create an invoice, payment, claim, exception, recovery receipt, recovery action and evidence item.
3. Verify a viewer/auditor cannot write those records.
4. Verify hospital A users cannot read hospital B records.
5. Attempt an over-recovery receipt and confirm the database rejects it.
6. Create two simultaneous active recovery actions for one exception and confirm the database rejects the second.
7. Upload evidence and confirm it is accessible only through an authenticated, short-lived signed URL.
8. Click **View** on an evidence item and verify the secure viewer works.
9. Verify audit records are created with the authenticated user's ID and cannot be edited/deleted by the client.

## Release rule

Do not put real hospital/patient financial data into the pilot until the security tests above pass and the Supabase project confirms the hardened RLS/storage policies are active.


## Additional static-review findings — 2026-10-11

### 7. Inline event-handler argument encoding — HIGH

A number of dashboard buttons pass database-derived values (including claim references and payer names) into inline JavaScript handlers. HTML escaping alone is insufficient because HTML character references are decoded before the browser parses the event-handler JavaScript.

**Action in branch `pilot-readiness-audit-v1`:** dynamic arguments in inline event-handler attributes are now escaped for JavaScript string-content context and then for the containing HTML attribute. This is a defense-in-depth fix; before pilot sign-off, review whether any other dynamically generated inline handlers remain and consider replacing inline handlers with delegated event listeners entirely.

### 8. Recovery status model mismatch — HIGH

The applied `supabase-pilot-hardening-v1.sql` constraint accepts `not_started`, `partially_recovered` and `fully_recovered`, while the application workflow also uses `in_progress`. The old `written_off` option was unsupported and there is no proper write-off amount/reason/approval ledger.

**Implementation in branch:** `supabase-pilot-status-alignment-v1.sql` safely extends the database constraint to include `in_progress` without rerunning v1 or rewriting existing recovery amounts. The UI supports those four statuses and no longer offers `written_off`. An exception cannot be resolved while exposure remains outstanding.

**Required before deploying the branch:** review and run the status-alignment migration after `supabase-pilot-hardening-v1.sql`. Keep write-off unavailable until the write-off amount, rationale, approval and subsequent-recovery accounting are properly designed and tested.

### 9. Audit-log authenticity — HIGH

The client-facing audit-log insert policy restricts `user_id` to the authenticated user and scopes rows to the user's hospital, but an authenticated member can still submit arbitrary client-originated `event_type` and `detail` values. Append-only access does not by itself prove that an event represents a real workflow action.

**Implementation in branch:** `supabase-pilot-audit-v2.sql` adds an explicit `source` label and database-trigger audit entries for insert/update/delete operations on invoices, payments, claims, exceptions, recovery transactions, recovery actions and recovery evidence. The new policy permits only client-tagged activity and blocks client inserts using the reserved `db_*` event namespace. The UI labels the source to distinguish the two categories.

**Required before this is considered active:** review and apply this follow-on SQL migration after `supabase-pilot-hardening-v1.sql`, verify seven triggers are enabled, and confirm an authenticated mutation creates a `source='database_trigger'` row while a client attempt to spoof a `db_*` event is rejected. This migration has not been run against the Supabase project.

### 10. CSV formula injection — MEDIUM

CSV exports originally quoted fields containing commas, quotes or newlines, but quoting alone does not prevent spreadsheet formula execution.

**Implementation in branch:** all 13 export serializers use shared `csvSafeCell()` / `csvRows()` helpers. Formula-leading text (including common leading whitespace/control characters before `=`, `+`, `-` or `@`) is prefixed safely, while genuine numeric values are retained as numeric cells.

**Required verification:** run the branch smoke tests and manually open sample exports in a spreadsheet application with adversarial test strings before merging.

## Updated pilot decision

The focused SQL tests and signed-URL document-view test have passed in the demonstrated workspace. The product is **not yet approved for real hospital data**: address the recovery-status/write-off mismatch and audit-log authenticity design before pilot sign-off, and merge the inline-handler hardening only after review/testing.


## Branch changes for review — 2026-10-11

- Dynamic inline-handler arguments are escaped for JavaScript string content before HTML attribute encoding.
- CSV export serialization is centralised and formula-safe; Node unit tests cover formula prefixes, CSV quoting and normal values.
- A Node-based syntax test compiles each inline application script without executing it.
- GitHub Actions workflow `.github/workflows/pilot-safety-tests.yml` runs the safety tests on PRs and pushes.
- `supabase-pilot-status-alignment-v1.sql` allows the UI's `in_progress` recovery status; `written_off` remains unavailable pending a proper accounting model.
- Follow-on migration `supabase-pilot-audit-v2.sql` adds database-generated audit source records for core financial/recovery table changes. It is not yet applied to Supabase.
- Review pull request: #4.

## Required sequence and remaining release gates

1. Run the CSV safety, inline-handler encoding and embedded-script syntax tests in GitHub Actions; resolve any failures.
2. Review and run `supabase-pilot-status-alignment-v1.sql` after the already-applied `supabase-pilot-hardening-v1.sql`.
3. Review and run `supabase-pilot-audit-v2.sql`; confirm seven triggers are enabled.
4. Verify an authenticated mutation creates a `source='database_trigger'` audit row and a client attempt to insert a `db_*` event is rejected.
5. Regression-test affected inline-handler buttons using payer names and claim references with apostrophes, backslashes, quotes and punctuation.
6. Manually open representative CSV exports with malicious-looking test values in a spreadsheet tool.
7. Design the write-off accounting workflow before reintroducing it.
8. Complete backup/restore, session-expiry and full workflow regression tests.
9. Do not load real hospital/patient financial data until these gates pass.


## Audit spoof test follow-up — 2026-10-11

The first audit test created one database-generated audit row but the client spoof attempt was accepted. The additional migration `supabase-pilot-audit-v3-policy-fix.sql` was then applied in Supabase. The policy inspection showed RLS enabled and only the intended member SELECT and restricted INSERT policies.

**Retest result (2026-10-11): PASS for the exercised path.** The invoice insert generated exactly one audit row, the authenticated client spoof attempt was rejected by RLS, and the temporary invoice was visible as one row before `ROLLBACK`.

**Still required:** run a post-rollback cleanup check and confirm both the temporary invoice count and forged-event count are zero. Gate 3 should not be marked fully closed until that cleanup check and the remaining regression tests are complete.