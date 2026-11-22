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

Each collection request names the exact target revision it expects the deploy
pipeline to report. A missing signal or a signal for another revision records
unknown evidence and does not execute the read check. An attempt is uniquely
identified by project, source issue number, criterion, check key/version, and
deployed revision. It retains project/account scope,
execution time, result, and terminal status. Retrying an identical deployment
updates the same row; a new revision creates a new historical row. The current
evidence projection exposes only a succeeded row whose revision equals the
deployment signal, while retaining stale and failed rows for provenance.

In development, where the running application uses the live checkout instead
of a release artifact, Paid identifies the checkout by its HEAD commit and a
digest of tracked and untracked source changes. The digest changes when the
mounted source changes, so a prior measurement becomes stale. Production
continues to require an explicit deploy-pipeline signal; a Git checkout in a
control-plane process is not evidence of a production deployment. If the
development checkout cannot be identified, the signal remains unavailable.

The #4812 check counts active `agent_planning_hold_reconciliation`
notifications whose Issue source is closed. It also reports the active total
for that source and project scope. The development baseline of 36 is recorded
as context only; the live target is zero and can be established only by a
post-deploy execution.

The worker-adoption check is a separate, narrowly scoped live observation. In
the production topology the collector (`RunCheckJob` in the `job` container)
cannot read the worker roles' readiness flag files or probe their PIDs — each
role is an independent container. Each Temporal worker role therefore
publishes its own readiness identity — PID, boot time, raw boot revision,
boot-time deployment identity, and a periodic heartbeat timestamp — into a
fixed system-wide `poll`/`agent`
observation table through the shared application database. A process boot is
identified by role, PID, and readiness time, so old and new containers remain
independently visible while a rolling deploy overlaps them. The check reads
only those durable, role-authored observations. Its evidence projection keeps
every observation whose heartbeat could fall in the live overlap window; when
a role has none, it keeps only that role's newest stale observation so stale
remains distinguishable from missing without copying unbounded restart history.
For each projected instance it retains only the PID, boot time, raw boot
revision, boot-time deployment identity, and latest beat. The check requires both
roles' observations to exist, carry a complete typed identity, be internally
coherent, carry a heartbeat the live worker itself refreshed within the
freshness window, and requires every fresh instance to equal the current
deployment identity. A stale superseded instance no longer blocks adoption,
but a fresh superseded instance does. Freshness is the
heartbeat, not the static boot receipt: a healthy worker keeps beating for its
whole lifetime, while a dead or interrupted worker stops, so long-lived
workers stay current and missing adoption fails closed. It returns unknown
evidence for a missing, stale, malformed, incoherent, or revision-mismatched
worker observation, and never accepts a host path, host command, process
argument, environment, credential, or foreign-namespace PID probe. The raw
boot revision remains available for the development updater's commit-adoption
contract. The recorder separately compares the worker's immutable boot-time
deployment identity with the complete current identity, including development's
HEAD and workspace-content digest, so same-HEAD source drift remains unknown
until the workers restart from that source. A worker snapshots that complete
identity before Rails loads application code and verifies the snapshot again
after routes, activities, workflows, and worker registrations are constructed.
The early identity capture uses only Ruby standard-library behavior because
Rails and Active Support are not loaded at that boundary in either development
or production.
If source changes across that startup boundary, the worker refuses to publish
readiness or begin polling; a post-load snapshot must not attest source newer
than the code already loaded into the process. The normal
measurement runner persists that typed result under the reviewed
project/account/criterion/revision mapping, so a heartbeat observation is an
input receipt rather than acceptance evidence by itself.
This deployment-adoption fact has intentionally narrow coverage: it does not
attest model behavior, credentials, request text, or any unrelated source
criterion.

`RunCheckJob` enters through the normal project-derived tenant context. The
operator task locates a project and loads its account with system read access,
then establishes that project's tenant context before invoking the same service.
This entry path works from a fresh process without an existing tenant context;
system access is limited to resolving that project and its account. A missing
deployment revision or synchronized source issue produces an inspectable
unknown attempt without querying the check. Database errors remain failed
attempts and are retried by the job under normal role restrictions.

A semantically changed measurement changes the closeout evidence digest and
enters the existing bounded acceptance-audit path. Volatile collection metadata
such as execution time remains visible to the assessor but does not create a new
evidence generation when an identical deployment is retried. The closeout
assessor, not the check, decides whether the exact criterion is now satisfied
and whether its matching prerequisite can be released. A passing count never
closes an issue or attests unrelated criteria.

Routine attempts are represented by the evidence/progress path. Action Required
is reserved for an unallowlisted request, missing deployment/source authority,
a check-reported unknown outcome, contradictory result, or repeated execution
failure. Each escalation names the exact failure reason and recovery context
and resolves on recovery.

## Decisions & Alternatives

| Decision | Rationale |
| --- | --- |
| Allowlisted application checks instead of supplied SQL | Keeps query shape reviewed, read-only, bounded, tenant-scoped, and compatible with normal database roles. |
| Revision-bound evidence instead of merge-bound evidence | A merged revision is not proof that the live dataset has been observed after deployment. |
| Reuse partial-closeout assessment | Only the existing criterion-level authority can release a prerequisite; a counter cannot make a whole-issue completion decision. |
| Fixed readiness reader instead of host tooling | Reuses #5293's safe role-specific metadata while preventing operator-selected host files, commands, SQL, process arguments, environment inspection, or credential reads. |
| Role-published durable heartbeats instead of cross-container file reads or PID probes | The job container cannot read worker containers' `/tmp` or see their PID namespace; the shared application database is the only authenticated channel every role already reaches, and a self-refreshed heartbeat distinguishes a live worker from a static boot receipt. |
