# RDR-063: Operational Supervisor for Delivery Health

> Revise during planning; lock at implementation. This is planning, not authorization to enable or implement autonomous mitigation.

## Metadata

- **Date**: 2026-10-27
- **Status**: Draft — awaiting normal design review
- **Type**: Operations + AI Safety + Automation
- **Priority**: P2
- **Related RDRs**: [RDR-011](RDR-011-observability.md), [RDR-047](RDR-047-work-category-queue-priority.md), [RDR-049](RDR-049-configuration-health-checks.md), [RDR-051](RDR-051-lid-aware-agent-runs.md), [RDR-054](RDR-054-prompt-assembly-service.md)
- **Related Intent**: [Operational supervisor](../intent/operational-supervisor/operational-supervisor-design.md) and [EARS](../intent/operational-supervisor/operational-supervisor-specs.md)
- **Related Issues**: #4341 (planning), #4699 (held implementation epic), #4700 (incident/policy persistence), #4701 (sanitized snapshot and analysis), #4702 (incident UI and narrow mitigations), #4703 (terminal audit)
- **Related Tests**: Planned: `spec/services/operational_supervisor/`, `spec/models/supervisor_incident_spec.rb`, `spec/jobs/operational_supervisor_job_spec.rb`, and dashboard request specs

## Problem

Paid already detects individual anomalies, caps PR follow-ups, pauses projects, prioritizes PR continuation, emits notifications, records execution audits, and refreshes selected dashboard metrics. These controls are local: they do not give an operator one account-scoped, privacy-safe view of whether paid work becomes merged pull requests efficiently. A failure can therefore look normal per run while repeated follow-ups, cost, queue age, or blocked work erode delivery across a project.

## Decision

Add a disabled-by-default Operational Supervisor as a bounded safety loop. It builds a deterministic, sanitized account snapshot; asks `agent_harness` to classify it through a strict structured response; persists first-class incidents; and, only when explicitly enabled, applies a small Rails-enforced allowlist. The first release is limited to incidents plus `pause_pr_followups` and `pause_project_autopick`; all other recommendations are incident-only.

The supervisor is not a general administrator, a quality scorer, or a source of repository diagnosis. Existing deterministic guards remain authoritative.

## Current evidence and selected boundary

The design reuses `AgentRunAnomaly` for per-run observations, `Notification` for existing consumer notifications, `ExecutionAuditEvent` for immutable execution audit patterns, project pause/scheduler controls, PR follow-up limits, `ProcessRunQueueJob` queue tiers, and GoodJob periodic sweeps. It does not extend `Notification` into an incident ledger: its single resolved/dismissed lifecycle and user-oriented dedupe are insufficient for immutable finding/action history, expiry, and supervisor health.

`SupervisorIncident` and `SupervisorMitigation` are separate account-scoped records. An incident carries a stable fingerprint, state (`open`, `mitigated`, `waiting_for_human`, `resolved`, `dismissed`), scoped foreign keys, sanitized evidence, analysis/prompt versions, and timestamps. A mitigation records its incident, target, action, precondition receipt, expiry, reversal, and audit-event reference. A `Notification` may link to an open critical incident, but never replaces it.

## Data boundary and analysis

The snapshot builder is deterministic Rails code. It may send only bounded numeric aggregates, enum categories, timestamps/ages, and Paid-local numeric account/project/issue/PR/run identifiers. Allowed measures are run/state/goal counts; token and cost totals and rates; follow-up and Paid-authored commit counts; lifecycle ages; queue depth; phase failure-category counts; CI/review enums; merged-PR yield; rework counts; cost per merged PR; and existing anomaly/incident severity counts. Missing or insufficient observations are explicitly `unavailable`, never zero.

The snapshot must never contain user or repository text, names, emails, issue or PR titles/bodies/comments, commit messages/diffs, paths or file content, prompts, agent logs/stdout/stderr/summaries, credentials, secrets, raw provider responses, or raw exception text. Candidate selection and size caps are mechanical pagination/ranking by published numeric measures; they make no quality or semantic judgment.

`OperationalSupervisor::Analyze` uses `agent_harness` only, with a fixed versioned prompt, JSON-schema response transport, and an allowlist supplied as data. Rails validates schema, enumerations, target membership in the snapshot, dedupe, authorization state, and current preconditions immediately before a write. Invalid output writes a low-noise supervisor-health incident and makes no mitigation.

## Actions, authorization, expiry, and recovery

| Action | Deterministic preconditions | Effect and recovery |
| --- | --- | --- |
| `pause_pr_followups` | Target is an open Paid PR in the snapshot; automatic follow-ups are active; no active mitigation exists. | Adds a supervisor-specific PR follow-up admission block. It expires after a configured bounded interval; expiry reverses only that block and records the reversal. |
| `pause_project_autopick` | Target project is active and in the snapshot; auto-pick is enabled; no active mitigation exists. | Adds a supervisor-specific fresh-issue admission block while preserving manual work and existing PR recovery/continuation. It has the same bounded-expiry reversal. |
| `open_incident_only` | Valid finding. | Persists no mitigation and requires a human decision. |

The implementation must not repurpose `Project#pause!`, alter a configured follow-up cap, change queue priority, terminate runs, mutate credentials/RBAC, or contact external systems. Those are distinct future decisions. No action may be inferred from semantic text or a hard-coded quality score: numeric thresholds are mechanical admission/expense policy stored as versioned, operator-configured data, while the LLM supplies semantic classification.

The account owner enables the supervisor explicitly; it is off for all accounts and projects by default. Autonomous mitigation additionally requires an account-owned policy record and the target project's opt-in. A project admin may dismiss/resume a project or PR mitigation within that project; account admins own account policy changes. Every mutation locks and rechecks the target, is idempotent on incident/action/target, and records an audit event. Expiry is a mechanical timeout, not a claim that meaningful progress occurred; human resolution remains visible after reversal.

## Delivery-health measures

The initial reporting window exposes issue-to-PR conversion, PR-to-merge conversion, merged-PR count, cost per merged PR, rework runs per PR, follow-up count, Paid-authored commit count, stage ages, queue depth/oldest age, phase failure-category count, guardrail rate, and continuation starvation. Each measure declares its observation window, denominator, source relation, and availability condition. The supervisor preserves unknown denominators and does not substitute accepted or open PRs for merged PRs. Long-running-client work is reported separately as in-flight inventory, not delivery success.

## Rollout Guard

`operational_supervisor_enabled` is an account-owned feature flag, default `false`, with a separately persisted project opt-in. Migration and read-only shadow snapshots may ship while the flag remains false; they create neither LLM calls nor mitigations. Enablement proceeds through test-account shadow mode, then reviewed account opt-in, then project opt-in. Rollback disables the account flag, prevents new analysis/actions, and reverses only active supervisor-owned mitigations. Cleanup removes expired mitigations and retains sanitized incident/audit records under the normal retention policy. External notifications are excluded until a later accepted RDR decision.

## Measurable acceptance

- A fixture with repeated automatic PR follow-ups, increased commits and token cost produces one deduplicated critical incident; an unrelated project has no mitigation.
- Snapshot contract tests prove every forbidden field is absent and every LLM call is made through `agent_harness` with schema-constrained output.
- Unknown, malformed, stale, unauthorized, or precondition-failing output persists no mitigation and records the appropriate incident/health outcome.
- An enabled and opted-in PR or project action is idempotent, audit-recorded, narrowly scoped, visible above dashboard metrics, and reverses only its own overlay at expiry.
- Disabled accounts perform no supervisor LLM call or mitigation; the release can be rolled back by disabling the flag and no external notification is required for dashboard visibility.

## Implementation tree and holds

The filed implementation tree is #4699 → #4700/#4701 → #4702 → #4703. Every implementation issue remains under the `planning` hold, uses no priority above P2, and is blocked by the merged design artifact in #4341. The terminal audit uses non-closing `Tracks #4699` language and validates runtime behavior, tests, documentation, flag posture, and retained evidence rather than inferring completion from closed children.

## Deferred decisions

- The exact retention duration and whether sanctioned incident exports need a separate redaction review.
- Whether external notification subscribers are warranted after internal incident semantics have production evidence.
- Whether future account-wide mitigation needs a distinct authority model.
