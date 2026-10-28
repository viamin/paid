# RDR-063: Operational Supervisor for Delivery Health

> Draft for normal design review. This record authorizes planning and a disabled-by-default observation slice only; it does not authorize mitigation.

## Metadata

- **Date**: 2026-08-17 (revised 2026-10-28)
- **Status**: Draft
- **Type**: Operations + AI Safety + Automation
- **Priority**: P3
- **Related RDRs**: [RDR-011](RDR-011-observability.md), [RDR-047](RDR-047-work-category-queue-priority.md), [RDR-049](RDR-049-configuration-health-checks.md), [RDR-051](RDR-051-lid-aware-agent-runs.md), [RDR-054](RDR-054-prompt-assembly-service.md)
- **Related Intent**: [Operational Supervisor LLD](../intent/operational-supervisor/operational-supervisor-design.md), [EARS](../intent/operational-supervisor/operational-supervisor-specs.md), [arrow](../arrows/index.yaml)
- **Related Issues**: #4341 (planning), [#4708](https://github.com/viamin/paid/issues/4708) (held epic), [#4709](https://github.com/viamin/paid/issues/4709), [#4710](https://github.com/viamin/paid/issues/4710), [#4711](https://github.com/viamin/paid/issues/4711), [#4712](https://github.com/viamin/paid/issues/4712), [#4713](https://github.com/viamin/paid/issues/4713), [#4714](https://github.com/viamin/paid/issues/4714)
- **Related Tests**: `OPERATIONAL-SUPERVISOR-001` through `OPERATIONAL-SUPERVISOR-010` (planned; no runtime implementation exists)

## Problem and current evidence

Paid must detect delivery-system failures that are not visible from one run: runaway PR follow-ups, rising cost with no completed delivery, a stalled queue, or correlated phase failures. The prior draft correctly prohibited exposing client material to an LLM, but it assumed an autonomous mitigation scope before the supporting incident, authorization, and expiry contracts existed.

This re-audit found no `OperationalSupervisor` implementation or prior issue tree. It also found shipped primitives that a new implementation must reuse rather than duplicate:

| Capability | Current boundary | Planning consequence |
| --- | --- | --- |
| `AgentRunAnomaly` and run/phase/cost records | Per-run statistical facts, not pipeline conclusions | Supply sanitized, aggregate facts only. |
| `Notification` severity/blocking and Inbox | Notification lifecycle is intentionally narrow | Do not overload it as an incident ledger; bridge to it only at presentation time. |
| PR follow-up limit, escalation, stale recovery, quality/project pauses | Existing, independently owned enforcement paths | Observation must not alter them; a later action must call its owner with fresh preconditions. |
| Category-first queue priority | Mechanical ordering of already-workable work | Do not let a supervisor re-rank work in the first release. |
| Execution audit events and tenant controls | Existing audit and account isolation conventions | Incident and later action records must be tenant-scoped and auditable. |

## Decision

Build a **disabled-by-default, account-scoped shadow supervisor** first. It constructs a bounded sanitized snapshot, asks `agent_harness` for a structured semantic classification, validates the response in Rails, and stores a durable operator incident. It has no enabled mitigation actions and cannot change admission, Auto-Pick, follow-up scheduling, queue priority, project settings, or external systems.

The draft deliberately does **not** finalize as implemented here. Design review must accept this record and the linked LID artifacts before the held tree starts.

## Safety and data boundary

The snapshot builder is deterministic Rails code. It may emit account/project/issue/PR/run identifiers, enum states, timestamps rounded to the documented window, counts, sums, rates with explicit denominators, and bounded top-N target rows selected by mechanical ordering. It may not emit:

- issue, PR, review, comment, commit, or repository text (including paths and diffs);
- prompts, agent summaries, stdout, stderr, logs, generated descriptions, or raw exceptions;
- user names, email addresses, credentials, tokens, secrets, provider payloads, or free-form metadata.

The LLM receives only that serialized snapshot plus a fixed policy prompt and JSON schema. All interaction goes through `agent_harness`; it has no database, shell, GitHub, or mutation capability. Rails rejects malformed output, unknown fields, unknown target IDs, and any output that violates the schema. Invalid analysis produces a low-noise supervisor-health incident and no mutation beyond that incident/audit record.

## Incident storage and lifecycle

Use a dedicated, tenant-scoped operational-supervisor incident model rather than extending `Notification`. Notifications have useful severity and Inbox presentation semantics, but do not own the incident fingerprint, repeated observation, snapshot provenance, action lifecycle, expiry/recovery evidence, or model/prompt identity needed here.

An incident stores only sanitized data: account and optional target IDs, category, severity, stable fingerprint, status (`open`, `waiting_for_human`, `resolved`, `dismissed`), first/last observed times, bounded evidence facts, snapshot schema/version and window, analysis model/prompt identity, and an append-only audit reference. An account-and-fingerprint uniqueness constraint and row lock make updates idempotent. The operator surface may project urgent open incidents into the existing dashboard/Inbox mechanisms; that projection is not the source of truth.

## Delivery-health metrics and judgment boundary

The snapshot reports mechanically observable measures with provenance:

- started runs, terminal outcomes, queue depth and age, and phase-failure counts;
- PR created/merged counts, follow-up counts, and time in lifecycle states;
- token/cost totals and rates; and
- guardrail, escalation, anomaly, stale, paused, and rate-limited counts.

Derived rates carry their numerator, denominator, window, and `not_available` state when a denominator is zero or the sample is insufficient. A merged-PR cost is reported only beside its completed-merge denominator; it is not a claim that unmerged work lacks value. Snapshot selection is bounded by fixed windows, cardinality, and stable ID/timestamp ordering. It does not encode a quality score, severity threshold, or semantic ranking.

Rails enforces structural policy (tenant scope, windows, bounds, schema, dedupe, authorization, and future preconditions). The LLM makes the semantic judgment of whether the sanitized pattern merits an incident. This preserves Paid's mechanical-policy/semantic-judgment boundary: no title matching, quality heuristics, or hard-coded scoring formula decides delivery quality.

## Authorization and future mitigation

In shadow mode, authorized account operators can view, dismiss, or resolve their account's incidents; those manual decisions are audited. No LLM response can execute an action. A later action needs a separately accepted RDR amendment and #4713 release of its planning hold. Each selected action must define:

- its narrowest target, existing owner service, and current-state preconditions;
- account/project authorization (project scope never implies account scope);
- a row-locked idempotency key and before/after audit evidence;
- a documented expiry or deterministic recovery condition, a human reset path, and a rollback operation; and
- a test proving a stale recommendation cannot mutate current state.

No action catalog is selected now. This intentionally leaves the old draft's pause/reprioritize proposals out of scope until shadow evidence and review establish that a specific existing control can safely own the effect. External notifications are also out of scope.

## Rollout Guard

Issue #4712 must add `operational_supervisor_shadow` to `FeatureFlags::DEFINITIONS`, default `false`, and read it with `FeatureFlags.enabled?(:operational_supervisor_shadow, project:)` before scheduling or publishing the shadow surface. Account-level enablement must be an explicit administrator-controlled setting; project evaluation is permitted only for projects in that enabled account. The guard permits observations and incident persistence only. It never permits an action.

- **Default / enablement**: false; an account administrator explicitly enables shadow observation after #4341 is merged and design review accepts this RDR.
- **Rollback**: disable the flag/setting; no new sweep or incident projection runs, while existing sanitized incidents and audit history remain readable.
- **Cleanup**: #4714 may recommend removing the guard only after accepted evidence proves the observation slice, its authorization, and the requested release posture. Mitigation requires its own later acceptance and guard.

## Measurable acceptance for the selected slice

- Fixture and contract tests prove that every forbidden data class is absent from snapshots, prompts, stored evidence, and audit metadata.
- A snapshot is account-scoped, deterministic for fixed input, bounded in rows and bytes, and reports each rate's window/numerator/denominator.
- Only `agent_harness` is used for analysis; malformed or unknown output creates no operational mutation.
- Incident creation/update is tenant-scoped, fingerprint-idempotent, audited, and visible to an authorized operator when the guard is enabled.
- With the guard disabled, no job schedules, no finding is published, and no supervisor path mutates delivery controls or external systems.
- Supervisor health exposes last successful and failed observation attempts without exposing forbidden data.

## Implementation tree and dependencies

All listed issues are P3 and held for planning/design acceptance:

1. [#4708](https://github.com/viamin/paid/issues/4708) is the umbrella and Tracks #4341 without closing it.
2. [#4709](https://github.com/viamin/paid/issues/4709) incident/audit contract and [#4710](https://github.com/viamin/paid/issues/4710) sanitized snapshot both depend on `viamin/paid#4341`.
3. [#4711](https://github.com/viamin/paid/issues/4711) analysis/validation depends on `viamin/paid#4709` and `viamin/paid#4710`.
4. [#4712](https://github.com/viamin/paid/issues/4712) shadow scheduling and operator surface depends on `viamin/paid#4709` and `viamin/paid#4711`.
5. [#4713](https://github.com/viamin/paid/issues/4713) is separately held for a later mitigation decision and depends on `viamin/paid#4712`.
6. [#4714](https://github.com/viamin/paid/issues/4714) is the terminal evidence audit, Tracks #4708 without closing it, and depends on `viamin/paid#4712` and `viamin/paid#4713`.

Closed child issues are not acceptance evidence. The final audit verifies code, tests, docs, guard posture, and shipped behavior before recommending umbrella closure; only the umbrella's own final audit may close it.

## Explicit unresolved decisions

- Design review must select any post-shadow mitigation one action at a time; none is authorized by this draft.
- #4709 must document the exact incident-to-Inbox projection after confirming the existing Notification policy can present it without becoming its ledger.
- #4710 must set the bounded window/cardinality values from operational capacity evidence, not quality scoring.
- Retention duration for sanitized incidents and snapshots needs the repository retention-policy owner before implementation.

## Consequences

The first release gives operators a durable, privacy-bounded delivery-health surface without turning an LLM into an administrator. It adds scheduled work, storage, and an additional health signal, but it avoids silently changing delivery behavior while the evidence for any mitigation is still absent.
