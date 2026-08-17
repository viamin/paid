# RDR-063: Operational Supervisor for Delivery Health

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-17
- **Status**: Draft
- **Type**: Operations + AI Safety + Automation
- **Priority**: P1
- **Related RDRs**: [RDR-011](RDR-011-observability.md) (Observability Stack), [RDR-015](RDR-015-end-to-end-optimization.md) (End-to-End Outcome Optimization), [RDR-023](RDR-023-automation-modularization-architecture.md) (Automation Modularization Architecture), [RDR-047](RDR-047-work-category-queue-priority.md) (Work-Category-Aware Queue Priority), [RDR-049](RDR-049-configuration-health-checks.md) (Configuration Health Checks), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-054](RDR-054-prompt-assembly-service.md) (Prompt Assembly Service)
- **Related Intent**: TBD
- **Related Issues**: TBD
- **Related Tests**: TBD

## Problem Statement

Paid's economic model depends on delivering high-quality merged pull requests, not merely running agents. A recent failure mode produced many PR-agent follow-up loops over roughly 24 hours, generated hundreds of commits, and burned hundreds of millions of tokens without corresponding delivery progress. Existing per-run anomaly detection and notification menu alerts are too narrow for this class of operational failure:

- a single run can look plausible while the issue-to-merged-PR pipeline is failing;
- notification-menu alerts are easy to miss during active incidents;
- deterministic thresholds catch known patterns but miss new combinations of symptoms;
- humans should not be the only backstop for obvious runaway automation.

Paid needs an operational supervisor that watches the whole delivery system, identifies anomalous or unprofitable workflow behavior from sanitized operational statistics, takes bounded autonomous mitigation actions when safe, and places urgent findings at the top of the dashboard.

## Context

The current control plane already has useful pieces:

- GoodJob cron jobs for repeated maintenance sweeps.
- `Notification` records with severity, dedupe by source/subject, resolution, dismissal, metadata, action URLs, and dashboard nav sections.
- `AgentRunAnomaly` for per-run statistical outliers.
- PR progress-state logic and follow-up caps for review/create-pr loops.
- configuration health checks and notification rules.
- cost, token, quality, queue, and run-state metrics.

These pieces are necessary but not sufficient. The missing layer is a top-down supervisor that asks whether Paid is converting work into merged PRs efficiently and safely.

## Decision

Build an **Operational Supervisor** that runs on a regular schedule, analyzes sanitized operational snapshots with an LLM through `agent_harness`, creates visible dashboard incidents, and executes only allowlisted mitigation actions whose preconditions are enforced by Rails code.

The supervisor's mission is:

> Keep the issue-to-merged-PR pipeline healthy, economical, and trustworthy.

This is not a general-purpose autonomous admin. It is a bounded operational safety loop over delivery-health statistics.

## Goals

- Detect runaway loops, token/cost burn, repeated phase failures, and degraded delivery throughput.
- Watch the complete workflow: issue intake, auto-pick, agent execution, PR creation, review, CI, follow-up, escalation, and merge.
- Surface urgent incidents at the top of the dashboard, above live metrics.
- Autonomously stop or slow clearly harmful automation.
- Ask for human input when the resolution is ambiguous or requires business judgment.
- Keep all supervisor decisions auditable.
- Never send user-authored content, repository content, comments, diffs, prompts, logs, secrets, or private client data to the supervisor LLM.

## Non-Goals

- Do not give the LLM direct database write access.
- Do not let the LLM run arbitrary code or shell commands.
- Do not let the supervisor read issue bodies, PR comments, repository files, diffs, or agent stdout.
- Do not implement autonomous code fixes in v1.
- Do not replace deterministic guardrails such as token limits, cost budgets, stale-run detection, or PR follow-up caps.
- Do not depend on external notifications for incident visibility in v1.

## Sanitized Snapshot

The supervisor input is a compact JSON snapshot of operational facts. It may include identifiers needed to target actions, but not human-authored or repository-authored text.

Allowed inputs:

- account, project, issue, PR, and run IDs;
- project/repo slugs only when already visible in the Paid UI;
- run counts by goal/status/window;
- token and cost totals/rates by account/project/goal/window;
- commit counts on Paid-authored PRs;
- PR follow-up counts and progress-state summaries;
- stage ages for issue and PR lifecycle states;
- queue depth and oldest queued run ages;
- stale, paused, rate-limited, failed, and guardrail-paused run counts;
- phase failure counts and phase names;
- CI/review status categories as enums;
- merge counts, merge yield, rework rates, and cost per merged PR;
- existing notification/anomaly/incident counts and severities.

Forbidden inputs:

- issue titles and bodies;
- PR titles, bodies, comments, review comments, and thread text;
- commit messages and diffs;
- repository file paths or file contents;
- agent prompts, stdout, stderr, logs, summaries, and generated PR descriptions;
- user names, email addresses, credentials, secrets, tokens, and raw provider responses;
- arbitrary exception messages unless pre-classified and redacted.

The snapshot builder must be deterministic Rails code. The LLM receives only the resulting sanitized JSON.

## Supervisor Analysis

Add an analysis service, tentatively `OperationalSupervisor::Analyze`, that calls `agent_harness` with:

- the sanitized snapshot;
- a fixed policy prompt;
- the allowlisted action catalog;
- severity definitions;
- a required structured JSON response schema.

The response must contain:

```json
{
  "findings": [
    {
      "fingerprint": "stable-dedupe-key",
      "severity": "warning|critical",
      "category": "runaway_loop|delivery_stall|cost_burn|quality_regression|queue_starvation|supervisor_health",
      "confidence": 0.0,
      "summary": "short operator-facing summary",
      "evidence": [
        "operational fact from snapshot"
      ],
      "recommended_action": {
        "type": "allowlisted_action_name",
        "target": {},
        "parameters": {}
      },
      "requires_human": false
    }
  ]
}
```

Rails validates the schema, rejects unknown action types, clamps severity to known values, and ignores recommendations that fail deterministic preconditions.

## Delivery Health Signals

The supervisor should reason about both local incidents and top-down workflow health.

### Local Operational Incidents

Examples:

- one PR has too many `create_pr` runs in a rolling window;
- a Paid-authored PR has excessive commits with no merge progress;
- token or cost burn for one project/goal spikes far above its recent baseline;
- many runs fail in the same phase;
- stale/paused/rate-limited runs accumulate and block queue progress.

### Top-Down Delivery Health

Examples:

- opened PRs are not becoming merged PRs;
- cost per merged PR is rising;
- rework per PR is rising;
- issues are aging in queue or in progress;
- review and CI cycles are degrading;
- a project is consuming capacity without client-visible output;
- nearly-mergeable PRs are starved while new issues keep starting.

Core metrics:

| Metric | Why it matters |
|---|---|
| Issue-to-PR conversion | Measures whether picked work produces PRs |
| PR-to-merge conversion | Measures delivery, not activity |
| Cost per merged PR | Ties token spend to revenue-producing output |
| Rework runs per PR | Captures churn and quality drag |
| Commit count per Paid-authored PR | Detects thrash and runaway follow-up |
| Stage age | Finds work stuck in queue, execution, review, CI, or merge |
| Guardrail and escalation rate | Captures workflow trust erosion |
| Queue starvation | Finds projects or PR continuations not receiving capacity |

## Incident Model

Supervisor findings should be persisted as first-class operational incidents or as `Notification` records extended enough to serve that role. The implementation should choose the smaller option during design, but the dashboard needs incident semantics:

- stable fingerprint;
- severity;
- status: open, mitigated, waiting_for_human, resolved, dismissed;
- affected account/project/issue/PR/run IDs;
- sanitized evidence;
- action taken, if any;
- human decision needed, if any;
- timestamps for first seen, last seen, mitigated, and resolved;
- analysis model/version and prompt version;
- raw structured LLM output retained only if it contains sanitized fields.

Urgent open incidents render at the top of the dashboard before live metrics. The notification menu remains secondary.

## Allowlisted Actions

The LLM recommends actions; Rails executes them. Every action must have deterministic preconditions, idempotency, audit logging, and rollback or expiry behavior when applicable.

Good v1 actions:

| Action | Preconditions | Effect |
|---|---|---|
| `pause_pr_followups` | PR has repeated automatic follow-ups or exceeds cap | Stop queuing further `create_pr` runs for that PR until human reset or fresh meaningful progress |
| `escalate_pr` | PR is open and stuck/degraded | Mark PR/issue escalated with supervisor reason |
| `pause_project_autopick` | project-level burn/stall exceeds critical threshold | Stop starting new issue work while allowing PR continuation/recovery |
| `reduce_project_followup_cap` | loop risk is high and current cap is above safe floor | Temporarily lower follow-up cap with expiry |
| `prioritize_pr_continuation` | nearly-mergeable PRs are aging while new work starts | Bias queue toward existing PR completion |
| `enqueue_recovery_job` | stale/parked/queue recovery signal is present | Enqueue existing recovery job |
| `open_incident_only` | action is ambiguous | Create dashboard incident and require human input |

Unsafe for v1:

- arbitrary settings changes;
- deleting branches or closing PRs;
- force-pushing, reverting, or committing code;
- changing credentials, billing settings, or RBAC;
- contacting external systems beyond existing notification sinks;
- starting autonomous implementation work without human approval.

## Human Interaction

Some findings should ask for a human decision instead of acting:

- high spend but unclear business priority;
- possible client deadline risk;
- repeated quality failures that need product judgment;
- action would pause a large project or account;
- the LLM confidence is below the configured threshold;
- deterministic preconditions disagree with the recommendation.

Dashboard incident cards should show the evidence, the proposed action, and explicit buttons for allowed human decisions such as resume, keep paused, lower cap, dismiss, or create follow-up issue.

## Safety Invariants

- The supervisor LLM receives sanitized statistics only.
- All LLM calls go through `agent_harness`.
- The LLM cannot execute actions directly.
- Rails rejects any action outside the catalog.
- Rails rechecks current database state immediately before applying an action.
- Actions are idempotent by incident fingerprint and target.
- Actions that reduce automation should prefer narrow scope first: PR, then project, then account.
- Every autonomous action produces an audit record and a dashboard incident.
- The supervisor fails closed: invalid LLM output creates a low-noise supervisor-health incident and no mutation.
- The supervisor has its own health check so operators know if it stops running.

## Proposed Architecture

```text
OperationalSupervisorJob
  -> OperationalSupervisor::Snapshot
  -> OperationalSupervisor::Analyze
  -> OperationalSupervisor::ValidateFindings
  -> OperationalSupervisor::ApplyAction
  -> OperationalSupervisor::PublishIncident
  -> dashboard top incidents
```

### Snapshot

Build one account-scoped snapshot per run. Keep it small enough for predictable cost and latency. For large accounts, include aggregate rollups plus the top N anomalous projects/PRs by deterministic scoring.

### Analyze

Use `agent_harness` with a low-temperature model setting and strict JSON output. Include the action catalog in the prompt. Do not include examples containing user data.

### Validate

Reject:

- malformed JSON;
- unknown categories, severities, or actions;
- findings without evidence;
- target IDs not present in the snapshot;
- actions whose deterministic preconditions fail;
- findings that would duplicate an already-open incident without new evidence.

### Apply

Execute only allowlisted service objects. Each action writes an audit entry before and after execution.

### Publish

Create or update an incident with sanitized evidence. Broadcast dashboard updates so urgent incidents appear without a page refresh.

## Dashboard Placement

Render open `critical` and `warning` supervisor incidents immediately below the dashboard heading and above live metrics. Each card should show:

- severity;
- short summary;
- affected project/PR/run counts;
- evidence;
- action already taken;
- requested human decision, if any;
- links to filtered runs, project, or PR.

This must not rely on scrolling or on the notification menu.

## External Notifications

External notifications are useful but should follow the incident model rather than precede it. Slack, email, webhook, PagerDuty, or issue-filing integrations can subscribe to supervisor incidents once internal incident semantics are stable.

## Implementation Plan

1. Add intent docs and EARS specs for the supervisor data boundary, action allowlist, incident lifecycle, and dashboard placement.
2. Add the supervisor incident/action persistence model or extend `Notification` if it can carry the required state cleanly.
3. Implement deterministic snapshot generation.
4. Implement `agent_harness` analysis with strict structured output.
5. Implement validation and allowlisted action application.
6. Add the GoodJob cron job and supervisor-health signal.
7. Render unresolved urgent incidents at the top of the dashboard.
8. Add external notification subscribers after internal incidents are working.

## Acceptance Criteria

- A PR follow-up loop with excessive commits/runs/tokens produces a top-of-dashboard critical incident.
- The supervisor can pause further follow-up runs for the affected PR without pausing unrelated work.
- The supervisor can identify project-level delivery degradation, such as high cost per merged PR or rising rework rate.
- The LLM prompt receives no user-authored content, repository content, comments, logs, diffs, prompts, secrets, or raw exception text.
- Unknown or malformed LLM output cannot mutate application state.
- Every autonomous action is allowlisted, precondition-checked, idempotent, audited, and visible on the incident card.
- Operators can see when the supervisor last ran and whether it failed.
- External notifications are not required for urgent dashboard visibility.

## Open Questions

- Should v1 extend `Notification`, or should supervisor incidents get their own table with richer lifecycle fields?
- What default thresholds should deterministic pre-scoring use before involving the LLM?
- Which actions require account-admin approval versus project-admin approval?
- Should temporary mitigations auto-expire after a fixed window, after fresh meaningful progress, or only after human reset?
- Which delivery-health metrics should count only merged PRs versus accepted/open PRs in long-running client projects?

## Consequences

Positive:

- Paid gains a system-level safety loop for runaway cost and degraded delivery.
- Operators see urgent issues where they work, not hidden in a menu.
- The LLM adds pattern recognition without receiving client data or direct mutation power.
- Autonomous mitigation can stop obvious harm before a human notices.

Negative:

- Adds another scheduled operational component that must be monitored.
- Requires careful prompt/version/audit discipline.
- Bad thresholds can create noisy incidents or over-conservative pauses.
- Sanitized snapshots may omit context that would help diagnosis, so ambiguous cases still need humans.

## Recommendation

Proceed with the Operational Supervisor as a P1 planning track. Start with narrow, high-confidence mitigation for runaway PR follow-up loops and top-of-dashboard incidents, then expand into broader delivery-health actions once the incident history proves the supervisor is accurate.
