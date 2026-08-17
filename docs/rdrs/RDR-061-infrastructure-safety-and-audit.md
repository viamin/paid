# RDR-061: Infrastructure Safety Rails and Execution Audit Events

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-12
- **Status**: Draft
- **Type**: Operations + Security Architecture
- **Priority**: P1
- **Related RDRs**: [RDR-011](RDR-011-observability.md), [RDR-018a](RDR-018a-billing-aggregation.md), [RDR-025a](RDR-025a-runner-quota-tracking.md), [RDR-033](RDR-033-worker-pool-scaling-algorithm.md), [RDR-049](RDR-049-configuration-health-checks.md), [RDR-050](RDR-050-account-queue-fairness-mode.md), [RDR-057](RDR-057-remote-execution-data-contract.md) (data movement audit), [RDR-058](RDR-058-execution-authority-network-and-isolation.md) (network policy and authority audit), [RDR-059](RDR-059-immutable-agent-runtime-images.md) (image digest in audit), [RDR-060](RDR-060-external-execution-resource-ledger.md) (resource ledger IDs in audit events)
- **Related Issues**: #3353 (execution concurrency), #3354 (resource requirements), #3355 (infra cost accounting), #3357 (health/shutdown), #3359 (production readiness)

## Problem Statement

Cloud execution turns scheduler bugs, retry storms, leaked credentials, and runaway agents into infrastructure bills. Paid already has strong LLM cost tracking and several concurrency limits, but cloud production needs defense-in-depth safety controls and a security audit model that answers who caused execution infrastructure to exist, with what authority, and when it was destroyed.

This is distinct from customer billing. It is an operator safety and audit decision.

## Context

### Current Implementation

- `Capacity::RunAdmission` enforces per-user, per-project, per-host, and account create-PR ceilings; #3353 adds global/per-runner limits.
- `AgentRun` has statuses, timestamps, duration, token limit status, peak memory, runner handle, external metadata, and logs.
- `DispatchCircuitBreaker`, tenant/user settings, and runner quota tracking provide additional dispatch controls.
- `TokenUsageTracker` and `CostBudget` track LLM cost, not infrastructure spend.
- `ContainerMetric` samples Docker resource usage; #3355 proposes infra usage/cost records.
- Configuration and credential models often use Logidze, but there is no dedicated execution-security audit event stream.

### Forces and Constraints

- Provider-level quotas/budgets are necessary but not enough; Paid should fail closed before creating resources.
- Paid must preserve local Docker development without forcing cloud-only cost APIs.
- Audit records must not contain secret values.
- Operational telemetry and security audit history serve different readers and retention needs.
- Avoid customer billing scope.

## Research Findings

- Existing concurrency and dispatch controls provide a base, but they do not cover aggregate resource requests, provisioning rate, or explicit cloud emergency shutdown.
- Operational logs and usage metrics are useful telemetry, yet they are not a durable security-grade explanation of who authorized infrastructure actions.
- Provider quotas and billing alarms are necessary backstops, but they fail too late to be the primary product safety model.
- Infra cost accounting and customer billing are adjacent concerns, not substitutes for execution-safety gates and audit events.

## Proposed Solution

Paid should enforce infrastructure safety rails before provisioning and record security-relevant execution events in a distinct append-only audit model.

## Safety Rails

Paid-owned controls:

- maximum execution duration per run;
- maximum concurrent executions globally, per account, per project, and per runner/backend;
- maximum aggregate requested CPU/memory/disk globally and per runner/backend;
- maximum provisioning rate globally and per account/project;
- maximum resources per execution based on provider-neutral resource specs;
- maximum retry/provision attempts per run/attempt window;
- infrastructure cost/spend thresholds once #3355 exists;
- emergency execution disable/kill switch at global, account, project, and runner levels;
- behavior when limits are reached: queue/park for capacity, fail fast for policy/resource violations, cancel/cleanup for active runs when an emergency switch is enabled.

Provider-level controls:

- cloud quotas, billing alerts, budget notifications, IAM guardrails, and maximum task/machine sizes.

The controls are defense in depth. Provider quotas are the backstop, not the product behavior.

## Audit Event Model

Create a distinct execution audit event stream for security and infrastructure events. It should be append-only at the application level and structured enough for investigation.

Minimum event classes:

- execution requested/queued/admitted/rejected;
- runner selected and why;
- image identity resolved;
- credential classes granted (not values);
- network policy granted, including direct/internet exceptions;
- external resource provisioning requested/created/started/stopped/deleted;
- cleanup failed/retried/succeeded;
- policy exception approved/expired;
- emergency disable enabled/disabled;
- relevant security configuration changed.

Minimum fields:

- event name and version;
- timestamp;
- actor type/id (`user`, `system`, `temporal`, `runner`);
- account_id, project_id, agent_run_id, attempt_id;
- runner/backend key;
- image digest/architecture when known;
- credential classes granted;
- network policy;
- resource ledger IDs/provider IDs when known;
- correlation IDs: Temporal workflow ID, runner handle ID, request ID;
- metadata without secrets.

## Alternatives Considered

### Rely only on provider quotas

- **Pros**: No Paid implementation.
- **Cons**: Late failure, provider-specific, poor per-account/project attribution.
- **Decision**: Reject as sole control.

### Use only existing concurrency limits

- **Pros**: Already mostly implemented.
- **Cons**: Does not cover provisioning rate, aggregate requested resources, emergency disable, or spend thresholds.
- **Decision**: Keep, but extend.

### Build a full billing/rating engine

- **Pros**: Eventually useful.
- **Cons**: Out of scope; would delay safety controls.
- **Decision**: Reject.

### Add operational safety rails plus append-only audit events

- **Pros**: Smallest production-safe layer; complements #3353 and #3355.
- **Cons**: Requires careful event schema and retention.
- **Decision**: Adopt.

## Security Implications

- Audit events make direct network access, subscription-auth materialization, and policy exceptions visible after the fact.
- Secret values must be redacted by construction; store credential IDs/classes, not tokens.
- Audit retention should outlive operational logs.

## Operational Implications

- Safety rails fail closed before provider provisioning.
- Emergency disable must stop new dispatch immediately and trigger cleanup/cancel paths for selected scopes.
- Audit events should be queryable by run, project, account, runner, image, and resource.
- Alerts should fire on denied capacity, provisioning rate limit, emergency disable, cleanup failures, and provider quota/budget alarms.

## Migration and Compatibility

- #3353 supplies global/per-runner concurrency; this RDR adds aggregate resource, provisioning-rate, emergency disable, and spend thresholds.
- #3355 supplies infra usage/cost records; safety thresholds can start with configured resource ceilings and later include estimated cost.
- Existing structured logs remain telemetry; they do not replace audit events.
- Local Docker can use permissive defaults, but production should require explicit ceilings.

## Trade-offs and Consequences

- Some runs will queue or fail before reaching the agent; that is correct when infrastructure policy is the blocker.
- Audit records add storage volume but avoid reconstructing security history from mutable logs and scattered metadata.
- Spend thresholds based on estimates will be imperfect until provider-reported cost exists.

## Implementation Plan

1. Extend admission and scheduling checks so provider-neutral duration, concurrency, resource, retry, and provisioning-rate limits are enforced before provisioning.
2. Add emergency disable controls at global, account, project, and runner scopes with immediate dispatch stop and cleanup/cancel behavior.
3. Introduce a distinct append-only execution audit event model that records actor, authority, policy, image, runner, and resource identifiers without secrets.
4. Integrate resource-ledger, image-identity, and network-policy decisions so the audit stream can explain what infrastructure existed, with what authority, and why.
5. Layer infra cost thresholds onto the same safety path once #3355 cost records exist.

## Validation

- Verify runs are rejected or queued before provider provisioning when concurrency, aggregate resource, provisioning-rate, or policy limits are exceeded.
- Verify emergency disable prevents new dispatch immediately and drives cleanup or cancellation for affected active runs.
- Verify audit events are append-only at the application level and queryable by run, project, account, runner, image, and resource identifiers.
- Verify audit events record credential classes and policy exceptions without storing secret values or relying on mutable operational logs.

## Open Questions

- Should audit events be Logidze-backed Active Record rows, a dedicated append-only table, or also exported to external SIEM storage?
- What default production global limits should ship for a private single-user deployment?
- Which policy exceptions require human approval versus account admin configuration?

## Relationship to Existing Work

This RDR does not duplicate customer billing, LLM budgets, #3353 concurrency limits, or #3355 infra cost accounting. It defines the safety and audit envelope those pieces must satisfy before cloud production.
