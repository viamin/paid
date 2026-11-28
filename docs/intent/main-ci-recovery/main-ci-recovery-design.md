---
parent: PAID
prefix: MAIN-CI
---

# Default-branch CI recovery

## Boundary and policy

PR repair does not cover failures discovered after merge. An opt-in project
policy under `review_settings.main_ci_recovery` names required full-verification
workflow paths and a known-good executor revision. GitHub webhook completion
signals are authenticated with the existing repository HMAC boundary. Events
only wake reconciliation; GitHub API reads establish the current default branch,
exact SHA, workflow identity, and result. A periodic sweep reconciles missed
signals. Missing or truncated evidence never establishes full green coverage.

A tenant-scoped state row serializes the project's current failure episode and
last fully verified green default-branch revision. Reconciliation rereads the
branch before committing a transition; stale events cannot clear or reopen a
newer episode. Complete required push workflows must succeed at the current tip
before the state becomes healthy. The verified revision and full-run provenance
are the publication boundary for future Crystalball maps; a map artifact alone
cannot clear recovery.

## Recovery and authority

A confirmed main failure records bounded redacted logs, job identifiers and
failing RSpec locations before repair dispatch or infrastructure retry. Known
infrastructure failures receive at most one failed-jobs rerun per failed run.
Other failures enter the existing isolated create-PR agent flow, with a bounded
attempt count and existing budget, trust, project activation and runner admission.
The repair prompt includes the verified baseline, failure episode, actual
candidate history, and mandatory failing examples plus normal verification.
A tested revert is preferred only when attribution and rollback safety are
established by the agent; ambiguous history, data/schema changes, or unsafe
reverts require fix-forward work or an explicit decision. No code is executed on
the host from the failing revision, and no main reset, force push, or database
rollback is authorized. The recovery control plane remains on its configured
known-good revision; enabling policy requires that revision to have full green
verification evidence.

Active failure state is an internal technical merge blocker for ordinary PRs,
including final merge and credential fallback paths. The recovery lane admits
only a PR produced by the exact recorded repair run for that episode, at its
recorded result head, after complete current-head verification and the existing
review/authorization gates. It is not a label-based bypass. Recovery is prioritized
using existing coding priority and capacity, without changing account fairness.

## Rollout and acceptance

The feature is disabled by default. Devcontainer rehearsal uses simulated GitHub
responses and isolated databases; no live main failure or destructive recovery
experiment is part of acceptance. Record observation, dispatch and verified-green
timestamps. Sub-minute dispatch is an event-delivery target, not a suite-runtime
promise. Publication of actual Crystalball artifacts belongs to #5472 and must
consume this verified baseline rather than PR-selected coverage. Enable selective
PR execution only after the failure/blocker/repair/full-green/unblock rehearsal.

## Owner configuration

Configuration is an owner console operation; ordinary review-setting edits
preserve it. Set `review_settings["main_ci_recovery"]` to an object with
`enabled: true`, `required_workflows: [".github/workflows/ci.yml", ...]`, and
`executor_revision: "<40-character known-good control-plane revision>"`.
The running control plane must have matching `PAID_EXECUTOR_REVISION`. That
operator assertion must describe the actual running revision and its full-green
acceptance evidence; it does not verify or deploy an executor automatically.
Existing projects remain disabled and need no configuration migration.

Required paths must identify workflows that execute complete verification for
both main push runs and recovery PRs. A selected-test workflow is not eligible.
Issue #5472 must preserve a full-suite recovery route when adding prediction; until
that protocol exists, do not enable selective tests using this feature alone.
Missing state or coverage blocks merges for an enabled project. Reconcile an
initial full-green baseline before enabling normal automation. After two failed
repair attempts, retain the technical stop for investigation; no human hold
label is added automatically. Infrastructure retries wait up to five minutes
for an ambiguous request before allowing bounded repair dispatch.

Recent failed push runs are inspected when current verification is incomplete.
After a verified baseline exists, only failures ahead of that baseline may
start an episode. Historical failures behind repaired main cannot recreate it.
No CI runs are cancelled and no runner capacity is added.
