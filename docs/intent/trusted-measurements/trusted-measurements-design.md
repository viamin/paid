---
parent: PAID
prefix: TRUSTED-MEASUREMENTS
---

# Low-Level Design: Trusted Post-Deploy Measurements

## Purpose

Closeout evidence sometimes requires a bounded observation of the production
tenant dataset. A merged pull request or a development snapshot cannot attest
that observation. This segment collects those observations through reviewed
application code without granting an operator arbitrary database execution.

## Design

`TrustedMeasurements::ALLOWLIST` is the sole registry of checks. Each entry
names a versioned Ruby check that accepts a project, uses tenant-scoped
ActiveRecord reads, and returns a bounded structured result. The runner never
accepts SQL, a repository command, or a dynamically selected class.

An attempt is uniquely identified by project, source issue number, criterion,
check key/version, and deployed revision. It retains project/account scope,
execution time, result, and terminal status. Retrying an identical deployment
updates the same row; a new revision creates a new historical row. The current
evidence projection exposes only a succeeded row whose revision equals the
deployment signal, while retaining stale and failed rows for provenance.

The #4812 check counts active `agent_planning_hold_reconciliation`
notifications whose Issue source is closed. It also reports the active total
for that source and project scope. The development baseline of 36 is recorded
as context only; the live target is zero and can be established only by a
post-deploy execution.

`RunCheckJob` enters through the normal project-derived tenant context. The
operator task may locate a project with system read access, then establishes
that project's tenant context before invoking the same service. A missing
deployment revision or synchronized source issue produces an inspectable
unknown attempt without querying the check. Database errors remain failed
attempts and are retried by the job under normal role restrictions.

A completed measurement changes the closeout evidence digest and enters the
existing bounded acceptance-audit path. The closeout assessor, not the check,
decides whether the exact criterion is now satisfied and whether its matching
prerequisite can be released. A passing count never closes an issue or attests
unrelated criteria.

Routine attempts are represented by the evidence/progress path. Action Required
is reserved for an unallowlisted request, missing deployment/source authority,
contradictory result, or repeated execution failure. Each escalation names the
specific recovery action and resolves on recovery.

## Decisions & Alternatives

| Decision | Rationale |
| --- | --- |
| Allowlisted application checks instead of supplied SQL | Keeps query shape reviewed, read-only, bounded, tenant-scoped, and compatible with normal database roles. |
| Revision-bound evidence instead of merge-bound evidence | A merged revision is not proof that the live dataset has been observed after deployment. |
| Reuse partial-closeout assessment | Only the existing criterion-level authority can release a prerequisite; a counter cannot make a whole-issue completion decision. |
