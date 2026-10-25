---
parent: operator-inbox
prefix: PREREQ-EVIDENCE
---

# Low-Level Design: Prerequisite Evidence Validation

> Companion to [`operator-inbox`](../operator-inbox/operator-inbox-design.md)
> (the surface), [`partial-closeout-recovery`](../partial-closeout-recovery/partial-closeout-recovery-design.md)
> (the prerequisite notifications this validates for),
> [`container-runtime`](../container-runtime/container-runtime-design.md), and
> [`marketplace-tool-sidecars`](../marketplace-tool-sidecars/marketplace-tool-sidecars-design.md)
> (the execution contracts this consumes). Implements the recovery gap named by
> [#4643](https://github.com/viamin/paid/issues/4643): a technical prerequisite
> that asks for live execution evidence (#4604-shaped: fresh pinned run, native
> analyzer, allowlisted tool-sidecar interaction, cleanup artifacts) cannot be
> satisfied by telling an Inbox operator to "obtain a Docker-capable
> environment", because availability inside an investigating agent's workspace
> and availability in Paid's execution infrastructure are different facts.

## Problem

A partial-closeout prerequisite notification (source
`PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE`) can request execution
evidence that only Paid's real execution infrastructure can produce. The
operator who receives that Inbox item previously had no supported action that
(1) reports which execution hosts and tool/authorization policies are actually
available, and (2) runs the requested bounded validation in that infrastructure
with durable, linked evidence. Agents closed prerequisite owners without the
artifacts because their own workspaces had no Docker client — an environment
fact about the investigation workspace, not about Paid's execution hosts.

## Approach

A **capability-aware, bounded validation action** offered from the
prerequisite's Inbox item. It is a recovery action on an existing Inbox entry,
not a new lane, workflow runtime, approval authority, or evidence framework:

- **Inspection before execution.** `Prerequisites::CapabilityReport` reads the
  supported execution-host capabilities through the existing provisioner
  interface (`Containers::HostReadiness` — per-backend ping/daemon/network/
  image/proxy checks with remediation hints) and the current tool/authorization
  policy (`FeatureFlags` `marketplace_tool_sidecars` state, the account service
  image allowlist, and the account's active `tool` marketplace entries). A
  missing local Docker socket is only one backend's probe result; other
  configured backends are reported independently.
- **Bounded execution.** `Prerequisites::StartValidation` records one
  authorization-scoped validation per prerequisite issue (one *active*
  validation per issue; retries create a new generation after the previous one
  is terminal — the same no-in-place-retry posture maintenance reports use) and
  enqueues `PrerequisiteValidationJob`. `Prerequisites::ExecuteValidation`
  creates a synthetic `AgentRun` (`goal: validate_prerequisite`, `synthetic:
  true`, manual trigger, proxy token), provisions its isolated execution
  environment (`AgentRun#with_execution_environment`), clones the pinned
  checkout (`Containers::GitOperations#clone_and_setup_branch`, which records
  `base_commit_sha`), runs the selected native analyzer through
  `AgentRun#execute_in_execution_environment(..., stream: false)`, and — only
  when the rollout flag is enabled and the selected tool's image is allowlisted —
  attaches the allowlisted `tool` marketplace entry through
  `MarketplaceEntries::AttachToRun` and provisions/calls/cleans it through
  `Containers::McpProvisioner`, the RDR-073 contract.
- **Fail closed with the authorized action.** When no configured backend is
  healthy (`unavailable`), or a required flag/allowlist entry is missing, the
  validation does not run the affected check: it records a blocker carrying the
  exact authorized setup/approval action (flag enablement via tenant settings,
  image allowlisting via admin/owner `UserSetting`, host remediation hints) and
  finishes `blocked`/`unavailable`/`partial` accordingly. The validation never
  enables a flag, edits an allowlist, or retries an unchanged capability
  failure; the authorized action is a named human/operator step.
- **Durable, bounded evidence.** Each validation persists its capability
  snapshot, per-check evidence (stdout/stderr/exit status truncated to the
  same 10 KB bound pre-commit checks use, image reference/digest, checkout
  SHA, tool identity, endpoint URL/response shape, and cleanup evidence), and
  a terminal status that distinguishes `succeeded`, `partial`, `failed`,
  `cancelled`, `unavailable`, and `blocked`. Provisioning and cleanup also flow
  through the normal `ExecutionAuditEvent` lifecycle records.
- **Linkage without closing authority.** The validation links back to the
  prerequisite owner (`issue_id`) and is rendered on the prerequisite's Inbox
  item. It never resolves the prerequisite notification, closes the owner,
  publishes a source-closing reference, or edits `paid_state` — #4631 owns
  erroneous automatic closing references, and missing execution evidence keeps
  the owner open.

## Storage Contract

`prerequisite_validations` (new table; a bounded evidence record, not a
workflow):

- `account_id`, `project_id`, `issue_id` (the prerequisite owner; nullable for
  project-scoped validations started outside an owner), `requested_by_id`,
  `agent_run_id` (the synthetic evidence run).
- `status`: `pending`, `running`, `succeeded`, `partial`, `failed`,
  `cancelled`, `unavailable`, `blocked`. One partial unique index admits at
  most one `pending`/`running` validation per issue.
- `include_tool_sidecar` (default true), `analyzer_command` (bounded,
  operator-selected; defaults to the read-only `scc` probe installed in the
  agent image).
- `capability_snapshot` (jsonb): host readiness payloads, flag state, allowlist
  and tool-entry state captured when the validation ran.
- `blockers` (jsonb): array of `{check, reason, authorized_action}`.
- `result` (jsonb): per-check evidence keyed `native_analyzer` /
  `tool_sidecar`, plus `checkout`, `image`, `cleanup`, `endpoint` sections.
- `scope_digest`: digest of the policy inputs (flag state, allowlisted images,
  selected tool entry+version). A terminal validation whose stored digest no
  longer matches the current policy inputs is *stale* and the Inbox pane offers
  revalidation instead of presenting stale evidence as current.
- `started_at`, `completed_at`.

## API, UI, and Tool Contract

All surfaces enforce the existing project-scoped `run_agent?` authorization
(the same policy that gates continuations and bootstrap runs) and pass through
the same services:

- **Inspect** — `GET /projects/:project_id/agent_runs/execution_capabilities`
  renders the live capability report into the prerequisite Inbox pane. It
  performs no writes and never provisions.
- **Start / retry** — `POST .../validate_prerequisite` (and the
  `start_prerequisite_validation` MCP tool, confirmation-gated like
  `trigger_readiness_bootstrap`) creates the validation and enqueues the job.
  Starting while a validation is active is refused with its status; starting
  after a terminal validation is the idempotent retry (a new generation).
- **Cancel** — `POST .../cancel_prerequisite_validation` (and the
  `cancel_prerequisite_validation` MCP tool) marks an active validation
  cancelled; the executor checks the flag between phases, preserves collected
  evidence, and still runs cleanup.
- **Progress/result** — the Inbox pane (the `action_required` prerequisite
  item and the partial-closeout pane's human-evidence section) renders the
  latest validation for the issue: status, blockers with authorized actions,
  per-check evidence, linked run, and staleness.

## Isolation and Authorization Boundary

- The validation executes only inside the synthetic run's isolated container.
  There is no host shell path, no Docker socket mount, and no control-plane
  execution of repository code: analyzer and endpoint probes go through
  `execute_in_execution_environment`, tool provisioning through the hardened
  `McpProvisioner` tool arm, and cleanup through the normal run/sidecar
  cleanup paths. Normal image allowlists, network hardening, and the project
  budget check (`CostBudgets::Check`) apply unchanged.
- A missing capability or authorization is itself a recorded outcome with the
  named authorized action — never a silent flag flip, a bypassed gate, or an
  unchanged retry.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Evidence record | Dedicated `prerequisite_validations` table linked to the issue and synthetic run | Reusing `AgentRun#verification_result` alone; a new evidence framework | `unavailable`/`blocked` outcomes never provision a run, and Inbox queries need per-issue latest/scope-staleness without contorting run columns. One bounded table is storage, not a parallel framework. |
| Execution vehicle | Synthetic `AgentRun` (`goal: validate_prerequisite`, `synthetic: true`) provisioned through `with_execution_environment` | A bespoke container path; running probes on the control plane | Reuses AgentRun provisioning, execution, audit, cleanup, and tool-attachment infrastructure verbatim; the `Runners::TestAgent` smoke-test path is the shipped precedent. The `synthetic` flag keeps counters and dashboards unaffected. |
| Sidecar gating | The RDR-073 rollout flag and image allowlist gate the sidecar check exactly as they gate every run | Bypassing the flag "just for validation"; silently enabling it | Execution capability and rollout authorization are different facts; the validation must surface the authorized enablement action, not exercise an unauthorized path. |
| Retry semantics | One active validation per issue; a retry after a terminal status creates a new generation with a fresh capability snapshot | In-place retry; automatic re-runs | Prevents duplicate concurrent validations and keeps each evidence generation pinned to the capability/authorization scope it captured. Automatic retries of unchanged capability failures are explicitly refused (#4643). |
| Closing authority | None: the validation links evidence only | Auto-resolving the prerequisite notification or closing the owner | Missing execution evidence keeps the owner open (#4604); #4631 owns erroneous automatic source-closing references. The human who reviews the evidence uses the existing dismissal/resolution surfaces. |

## What This Is Not

- Not the RDR-075 maintenance runtime — it validates the prerequisite's
  execution-environment contract; it does not run maintenance recipes or
  produce maintenance reports.
- Not an approval authority — no flag, allowlist, or pilot authorization is
  granted by running it.
- Not a new Inbox lane — it is an action + evidence panel on the existing
  prerequisite Inbox item.

## References

- `docs/rdrs/audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md`
  — the #4604 evidence contract this validates for
- `app/services/prerequisites/` — capability report, start/execute/cancel
- `app/models/prerequisite_validation.rb`, `app/jobs/prerequisite_validation_job.rb`
- `app/controllers/projects/agent_runs_controller.rb` — Inbox actions
- `app/views/dashboard/_inbox_detail_prerequisite_validation.html.erb`
