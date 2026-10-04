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
