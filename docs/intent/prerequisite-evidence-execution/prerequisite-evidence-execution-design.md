---
parent: PAID
prefix: PREREQ-EXEC
---

# Low-Level Design: Prerequisite Evidence Execution

> Companion to [`docs/high-level-design.md`](../../high-level-design.md).
> Supplies the missing supported capability-aware execution action for
> technical prerequisite evidence
> ([#4643](https://github.com/viamin/paid/issues/4643)), owning the seam
> between a prerequisite Inbox item and Paid's existing execution
> infrastructure.

## Purpose

A technical prerequisite (for example
[#4604](https://github.com/viamin/paid/issues/4604): a fresh pinned
`AgentRun`, a native analyzer invoked through
`AgentRun#execute_in_execution_environment`, and an allowlisted
`tool_sidecar` interaction, each with cleanup evidence) can be closed with
"unavailable" by an agent whose own workspace lacks a Docker client or
socket. Availability in an investigation workspace and availability in
Paid's execution infrastructure are different facts. This segment gives an
operator one bounded, capability-aware action — reachable from the
prerequisite's Inbox surface — that inspects what Paid's execution
infrastructure actually supports and, when the required authorizations are
in place, collects the evidence through the normal isolated-run path.

This is not a new maintenance runtime, approval authority, or evidence
framework (see [maintenance-runs](../maintenance-runs/maintenance-runs-design.md),
RDR-075, which remains Draft and owns none of this): every execution,
attachment, provisioning, and cleanup path is the existing `AgentRun`
contract.

## Capability inspection contract

`PrerequisiteExecutions::Capabilities` answers, for a project and an
optional selected tool, "can Paid's execution infrastructure run this
validation right now, and if not, which exact authorized action changes
that?"

- **Execution-host capability** derives from the provisioner's own
  placement interfaces — `DockerHost.placement_ready_for_agent_runs` and
  the per-host readiness columns — never from probing the control plane's
  local Docker socket. A control plane without a local socket and a
  placement-ready remote/swarm host is an available environment; a control
  plane with a local socket and no placement-ready host is not.
- **Tool authorization policy** covers the `marketplace_tool_sidecars`
  rollout flag (checked against the project exactly as
  `Containers::McpProvisioner#tool_sidecars_enabled?` checks it) and the
  account's operator image allowlist (the same
  `UserSetting.allowed_service_images` union `McpProvisioner` fails closed
  on).
- Every missing requirement carries `kind`, `message`, and
  `authorized_action` — the exact human setup/approval step (enable the
  named flag as a tenant admin, add the named image to the allowlist,
  restore readiness on the named host, or add a Docker host). The service
  never enables flags, edits allowlists, or retries unchanged capability
  failures.

The report is a persisted snapshot (`capability_snapshot`) on each
validation attempt so the Inbox can render exactly what was inspected,
fresh per attempt.

## Storage contract

A `PrerequisiteExecutionValidation` (new model, not a run type) records one
bounded attempt:

- `project`, `issue` (the #4604-like prerequisite owner issue; one active
  attempt per issue), `agent_run` (the synthetic validation run), and
  `initiated_by` (the operator).
- `contract` — the explicit artifact contract captured at start: pinned
  `branch`, the native analyzer command, and the optional selected
  marketplace tool (entry + version identity). Immutable after start.
- `capability_snapshot` — the inspection result for this attempt.
- `steps` — one durable record per planned step (`checkout_identity`,
  `native_analyzer`, `tool_sidecar`): command, endpoint, exit status,
  bounded stdout/stderr, and timestamps.
- `evidence` — identity and cleanup artifacts: run container id/image,
  container host, checkout branch + resolved commit SHA, tool identity,
  provisioned sidecar endpoints, and the cleanup disposition of the run
  container and sidecars.
- `status` — `pending`, `preparing`, `running`, or terminal
  `succeeded` / `partial` / `failed` / `cancelled` / `unavailable`.
- `scope_digest` — digest of branch + command + tool identity + tool-flag
  state, used for idempotency and stale-evidence detection.
- `stale` — set on prior attempts when a new attempt starts with a changed
  scope, so changed scope forces revalidation instead of reusing evidence.

### Outcome taxonomy

| Status | Meaning |
| --- | --- |
| `unavailable` | A required host capability or authorization was missing before execution; nothing ran. Not an execution failure. |
| `succeeded` | Every planned step completed with exit status 0. |
| `partial` | At least one planned step completed and at least one did not; collected evidence is preserved. |
| `failed` | No planned step completed successfully (including pre-execution errors after provisioning). |
| `cancelled` | An operator cancelled; evidence collected so far is preserved. |

The paired `AgentRun` is marked with the matching terminal status
(`succeeded`/`partial` → `completed`, `failed`/`unavailable` → `failed`,
`cancelled` → `cancelled`).

## Execution lifecycle

`PrerequisiteExecutions::Start` (prepare/start/resume) is idempotent and
gated:

1. Resolve the prerequisite issue and optional tool (an `entry_type:
   "tool"` marketplace entry of the account).
2. Inspect capabilities. Missing requirements → record an `unavailable`
   attempt with the snapshot and actions; nothing provisions. An unchanged
   `unavailable` attempt (same `scope_digest`) is refreshed in place rather
   than retried.
3. One active attempt per issue returns the active attempt; a `succeeded`
   attempt for the same scope returns its existing evidence (no duplicate
   run).
4. Otherwise create a synthetic `internal_agent` `AgentRun` (goal
   `prerequisite_validation`, `trigger_type: manual`, pinned `branch_name`,
   default-deny ingress, no runner) plus the validation row, mark prior
   attempts with a different scope stale, and enqueue
   `PrerequisiteExecutions::ValidationJob`.

`PrerequisiteExecutions::Runner` executes the bounded contract inside the
job, reusing the shipped infrastructure step for step:

1. Provision through `AgentRun#provision_execution_environment` with a
   Paid-managed temporary `worktree_path` (the same bind-mount shape
   `PreviewSessions::ProvisionJob` uses). No host shell, no Docker-socket
   mount, normal image allowlists, hardening, and budgets apply.
2. Materialize the pinned checkout through `Containers::GitOperations`
   (`clone_and_checkout_branch`) and record the resolved commit SHA.
3. Run the native analyzer command through
   `execute_in_execution_environment(command, stream: false)` — the
   contract `PreCommitRequirements::Evaluate` already established.
4. When a tool is contracted, attach it through
   `MarketplaceEntries::AttachToRun` (which writes the immutable
   `tool_sidecar_snapshot`), provision through
   `Containers::McpProvisioner#provision` (flag-gated, image-gated,
   hardened), and call the provisioned endpoint from inside the run through
   `execute_in_execution_environment`.
5. Always clean up: sidecars via `McpProvisioner#cleanup_tool_sidecars`,
   the run container via `AgentRun#cleanup_execution_environment`, and the
   temporary workspace. Cleanup disposition is recorded as evidence.

Cancellation (`PrerequisiteExecutions::Cancel`) marks the attempt
cancelled, preserves collected steps, runs the same cleanup, and cancels
the paired run. The runner re-checks cancellation between steps.

## Inbox, UI, and API contract

The prerequisite surface is the partial-closeout Inbox entry's
Prerequisites section: it renders the capability report (compatible hosts,
tool-flag state), the exact authorized setup/approval actions for every
missing requirement, and the bounded validation action for each linked
open prerequisite issue. The same controller serves JSON for API consumers
(`capabilities`, `create`, `show`, `cancel`, `retry`), all authorized
through the project policy (`show?` for reads, `run_agent?` for actions) —
UI and API are the same contract, neither thicker than the other.

A completed validation links evidence back to the prerequisite issue on
the validation record and Inbox card only. It never closes, comments on,
or re-labels the GitHub issue: missing execution evidence keeps the owner
open (canonical evidence assessment stays with
[partial-closeout-recovery](../partial-closeout-recovery/); erroneous
automatic source-closing references are #4631's territory). An
agent-accessible tool surface, when one is needed, composes the same
services behind the same authorization — no separate action framework.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Where capability truth lives | `DockerHost` placement scopes + rollout flag + image allowlist reads | Probing the local Docker socket; live `Containers::HostReadiness` pings | The placement scopes are the provisioner's own admission surface, so the report cannot disagree with what provisioning would actually do; a local-socket probe answers the wrong question (control-plane workspace ≠ execution infrastructure). |
| Evidence record | New `PrerequisiteExecutionValidation` model linked to issue + run | Columns on `Issue`; reuse `AgentRun.verification_result`; notifications as storage | The attempt needs its own lifecycle (idempotent retry, staleness, steps) without overloading issue or run semantics; notifications are a surface, not a store. |
| Execution vehicle | Synthetic `internal_agent` run, goal `prerequisite_validation`, executed by a dedicated job | A real runner through Temporal; host-side execution | Reuses the shipped provision/execute/cleanup contract exactly (the `PreviewSessions::ProvisionJob` precedent) without inventing a Temporal workflow for a bounded operator action; untrusted repository code runs only inside the container. |
| Flag-off behavior | `unavailable` before execution, with the exact admin action; never auto-enable | Run native-only and mark sidecar skipped | Running half a contract would manufacture partial evidence for an explicitly required artifact; the flag is a rollout authorization, and distinguishing capability from authorization is the point. |
| Retry semantics | Same-scope `succeeded` returns existing evidence; `unavailable` refreshes in place unless scope (incl. flag state) changed; changed scope marks old evidence stale and revalidates | Unlimited fresh attempts | Idempotent retry must not duplicate successful evidence or silently re-run unchanged capability failures; scope digest includes flag state so enabling the flag is a real scope change. |

## What This Is Not

- Not an approval authority — nothing here closes issues, merges, grants
  rollout, or bypasses flags, allowlists, budgets, or holds.
- Not a maintenance runtime (RDR-075 owns that, still Draft); not an
  evidence-assessment framework (partial-closeout recovery owns
  reconciliation of collected evidence).
- Not host access — the validation runs only in the isolated run container
  with the normal hardening profile; the Docker socket is never mounted
  and no host shell is exposed.

## References

- [#4643](https://github.com/viamin/paid/issues/4643) — this segment's
  issue; [#4604](https://github.com/viamin/paid/issues/4604) the concrete
  evidence task; [#4614](https://github.com/viamin/paid/issues/4614)
  general recovery
- [2026-10-23 RDR-075 M00 tool-handoff validation
  report](../../rdrs/audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md)
  — the two required artifacts this action collects
- `app/models/agent_run.rb` — `provision_execution_environment`,
  `execute_in_execution_environment`, `cleanup_execution_environment`
- `app/services/containers/mcp_provisioner.rb`,
  `app/services/marketplace_entries/attach_to_run.rb`,
  `app/services/containers/git_operations.rb`
- `app/jobs/preview_sessions/provision_job.rb` — synthetic-run precedent
