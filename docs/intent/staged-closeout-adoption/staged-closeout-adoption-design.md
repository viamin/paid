# LLD: Staged Closeout Adoption

```yaml
parent: partial-closeout-recovery
prefix: STAGED-CLOSEOUT-ADOPTION
```

## Problem

Staged closeout verification needs an explicit project decision before a later
scheduler can run any check. Neither merge automation nor phase settings is
that decision, and untrusted issue, PR, or agent content cannot make it.

## Design

Each project has one default-off enrollment. An authorized project maintainer
may enable or disable it. Disabling it immediately makes every mapping
ineligible without deleting its history.

Enrollments, mappings, and their source issues are tenant-owned records. When a
project or its account is deleted, mappings are removed before their referenced
parents and reviewers so the ordinary owner lifecycle can remove the complete
adoption graph.

A reviewed mapping is an append-only revision for one source issue and stable
criterion string. It pins its stage, target shape, existing execution-path
key, version and digest, optional environment class, freshness, retry policy,
reviewer, and review time. Replacing or revoking a mapping retires the old
revision; future admission must select only the latest approved, current
revision. Review never creates a run. After an authoritative source-PR merge
observation, closeout verification admission selects each current
`merged_revision` mapping and creates one synthetic, queued
`closeout_verification` AgentRun. The run binds the project, source issue,
mapping/criterion, source PR number, observed merge SHA, and pinned recipe
version and digest. A database identity makes webhook replay, concurrent
observers, and Paid auto-merge/webhook overlap converge.

The goal is non-triggerable and excluded from the ordinary agent queue;
execution belongs to its dedicated successor work. Admission rechecks mapping
eligibility and automatic phase authority, rejects paused or inactive project
authority, and returns a stable, inspectable no-run reason. Completed evidence
with the same identity is current and is not replaced. A bounded sweep retries
persisted merged PR observations after a disabled enrollment is re-enabled or
a webhook was missed. `live_environment` mappings do not qualify from a merge:
they wait for a separately confirmed live target.

The dedicated closeout-verification worker claims only an admitted queued run.
Immediately before execution it rechecks the persisted mapping against the
source issue, recorded merged revision, reviewed recipe version and digest,
automatic Release & Deployment policy, pause state, and budget. It resolves no
command from issue or PR content: the existing `TechnicalPrerequisites::ValidateExecution`
path receives only the currently matching reviewed recipe and performs the
pinned checkout inside its isolated container. The terminal run retains a
bounded closeout evidence envelope with the source/criterion/PR/revision,
recipe and environment identity, command result, artifacts, timing, and a
distinct pass, fail, unavailable, cancelled, stale, timeout, setup, or cleanup
outcome. A terminal identity is never executed again.

For projects with an adoption record, an incremental issue payload reporting a closed PR resolves its authoritative
PR detail before committing that closure. A confirmed merge records the merge
revision and invokes the same admission path as a webhook or Paid merge.
Unavailable PR detail leaves the sync watermark unchanged for retry; closure
without a confirmed merge cannot create verification work.

Review requires a current closeout assessment. Admission for an observed merge
may reuse that reviewed criterion when the assessment's intent revision still
matches the issue, even though the merge has made its delivery evidence stale.
Changed intent, removed criteria, revoked mappings and changed checks remain
blocking. Scheduling a check never refreshes the acceptance assessment or
changes a criterion's verdict; fresh acceptance evidence is still required for
closure.

Mapping admission validates the criterion against the current persisted
closeout assessment, project/account scope, stage-to-phase pairing, and the
existing permitted registry. Checkout validations resolve an enabled effective
`PreCommitRequirement`; live observations resolve only
`TrustedMeasurements::ALLOWLIST`. The stored immutable digest is recomputed at
admission, so a changed recipe/check makes the mapping ineligible.

The project closeout adoption surface and its JSON representation use the same
service and `ProjectPolicy#update?` authorization as any API/agent caller.
Project settings link to an HTML review page for enrollment, criterion/check
selection, replacement, revocation, and history. The page selects only current
assessed criteria and existing permitted recipes or trusted checks; it never
accepts an executable command. Each mapping exposes its reviewer, review time,
bound inputs and eligibility reason. Reviewed inputs cannot be edited in place,
and admission rejects a mapping belonging to another issue or project.

The curated Fully Automatic profile (`solo_automated`) carries the enrollment
as an explicit operating-mode target through the shared
`Configuration::Profiles::Settings` descriptor registry. Applying or
reapplying the profile stages the enrollment change through the normal
planner/applier authorization and audit trail; persistence keeps the
enrollment's reviewer identity and revision history, and serializes first
enrollment creation with the project row so concurrent applies converge on one
enrollment. Every other curated
profile explicitly pins the target off. The profile target controls
eligibility only: it never approves arbitrary commands, invents criterion
mappings, enables a deployment executor, or overrides phase policy — absent an
approved mapping or available target the project keeps an inspectable waiting
reason.

The legacy `ConfigurationProfiles` compatibility facade preserves its
actor-optional contract by authorizing this enrollment target before it stages
the target. If the caller lacks `ProjectPolicy#update?`, the facade reports the
enrollment change as skipped and applies every other profile target.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Revision rows instead of in-place edits | Keeps the reviewed decision and invalidation history inspectable. | Editing the current mapping would erase the approval it superseded. |
| Registry references only | Prevents this feature from becoming a command or deployment executor. | Accepting arbitrary commands or targets would bypass existing authorization. |
| Merge identity stored on the source PR and run | Lets a bounded sweep recover missed delivery without treating merge as deployment, while preserving exact evidence provenance. | Re-fetching GitHub for every sweep would make recovery depend on a live provider read and obscure the observed target. |
| Explicit profile target for Fully Automatic | Enrollment flows through the reviewed planner/applier with the same per-level authorization and rollback as every other posture lever. | Deriving enrollment silently from merge/release settings would hide the adoption decision. |
