# RDR-075: Layered Verification Add-on (Defense in Depth)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-10-13
- **Status**: Draft
- **Type**: Architecture + Quality + AI Safety
- **Priority**: P1 `[inferred — not supplied by the feature brief]`
- **Related RDRs**: [RDR-011](RDR-011-observability.md) (Observability Stack), [RDR-045](RDR-045-live-web-app-preview-agent-verification.md) (Live Web App Preview and Interactive Agent Verification), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-056](RDR-056-strict-test-driven-development-mode.md) (Test-Driven Development Modes), [RDR-061](RDR-061-infrastructure-safety-and-audit.md) (Infrastructure Safety Rails and Execution Audit Events), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md) (Feature Intent and Approval Lifecycle), [RDR-067](RDR-067-approved-intent-conformance.md) (Approved Intent Conformance)
- **Related Issues**: implementation issue tree to be filed after this RDR PR; numbers will be recorded in the epic issue
- **Related Intent**: to be created by the `lid_planning` run after this RDR is accepted

## Problem Statement

**Proposed framing `[inferred — not user-confirmed]`**: Paid has multiple ways to
inspect, test, review, and approve agent-produced changes, but the feature brief
asks for a single defense-in-depth verification add-on that selects the least
expensive sufficient set of checks, preserves evidence, detects when evidence
is stale, and gives humans a business-readable decision package.

The desired outcome is trustworthy change delivery with proportionate cost and
review effort. The brief supplies no customer measurements or confirmed claim
that current verification is inadequate; this RDR therefore specifies a
capability and its acceptance evidence, not an assertion that an outcome has
already been achieved.

The add-on must support three entry paths `[inferred]`:

1. **Agent-run entry**: verification requested as part of an agent run before
   delivery.
2. **PR/review entry**: verification requested for an existing pull request or
   review/quality decision.
3. **Human/business-review entry**: a reviewer needs a synthesized package,
   traceability, approval, or an exception decision before proceeding.

The exact request and lifecycle names remain a LID-planning decision.

## Context

The feature brief explicitly requests a layered verification add-on covering
purpose, authority and interpretation, the three entry paths, nine verification
layers, a business-facing review package, selection rubric, evidence and
traceability, change detection and repair, coverage synthesis, cost/adoption
principles, and ten acceptance criteria. It does not provide customer evidence,
implementation names, or user-confirmed problem framing.

Paid has the following observed host capabilities:

- `AgentRuns::Verification` provisions the existing browser verification
  container and Playwright MCP path; `AgentRuns::VerificationResultRecorder`
  normalizes and persists verification status, summaries, artifacts, and
  change-surface metadata on an agent run. See RDR-045 and the corresponding
  services under `app/services/agent_runs/`.
- `Reviews::Verification::Pipeline` already implements a staged
  find/verify/synthesize flow, pins a PR head, retries once when the head moves,
  groups findings, and posts tracked review output. Its layer-specific services
  include `FindCandidates`, `VerifyCandidates`, `SynthesizeReview`, and
  `ChangedLines`.
- `Activities::CheckQualityGateActivity` evaluates recent quality metrics,
  supports explicit/manual/priority bypasses, and returns an auditable gate
  result. Quality metrics, thresholds, pauses, and recovery services exist under
  `app/services/quality_*` and `app/models/quality_*`.
- Feature-intent approval and conformance services exist under
  `app/services/feature_intents/` and `app/services/intent_conformance/`,
  including merge-time verification and review scheduling.
- `Audit::RecordEvent`, `ArtifactStorage`, knowledge artifacts, and the
  execution/audit services provide existing persistence and audit patterns.
- LID requires intent to flow HLD → LLD → EARS → tests → code. RDR-051 and
  `Prompts::BuildForCreateFeature` define the later `lid_planning` conversion;
  this RDR therefore uses stable proposed `@spec LAYERED-VERIFY-*` IDs for the
  future issue tree.

These observations establish reusable boundaries, not proof that a layered
coordinator, universal evidence schema, business review package, or coverage
synthesis already exists. Those are missing components to design and implement.

## Research Findings

1. **Verification is currently distributed.** Browser verification and result
   recording are separate from PR review verification and quality-gate
   evaluation. The repository has no observed single coordinator that selects
   and runs a cross-layer plan for all three entry paths. `[inferred gap]`
2. **Evidence exists in several shapes.** Run verification results contain
   normalized artifacts and status; review verification has candidates,
   verdicts, changed-line anchors, and synthesis; quality gates return metrics
   and breaches; intent conformance records decisions. No observed common
   evidence envelope connects all of those results. `[inferred gap]`
3. **Change awareness is established in individual flows.** The review
   pipeline rechecks the PR head and `ChangedLines` validates anchors. Agent-run
   verification records a result commit and changed surfaces. The brief asks to
   generalize this into invalidation and repair across selected layers.
4. **Policy and approval boundaries already matter.** Quality gates can block
   continuation, feature-intent workflows model approval, and intent conformance
   verifies at merge. The add-on must consume those authorities rather than
   silently replace them. `[inferred design constraint]`
5. **The existing architecture delegates semantic judgments to AI and keeps
   structural safety in Rails.** `docs/STYLE_GUIDE.md` describes Zero Framework
   Cognition; the review pipeline mechanically validates model output and
   anchors. The coordinator should apply deterministic policy, budgets,
   freshness, and state transitions while layer-specific semantic judgments stay
   in their existing services or approved agent-harness calls.
6. **No evidence was found in the reviewed files of a business-facing,
   cross-layer verification package or a coverage matrix.** The package and
   synthesis contract are therefore proposed new components, not renamed claims
   about existing behavior.

## Proposed Solution

Build a policy-driven **Layered Verification Coordinator** that accepts one of
the three entry-path requests, resolves the authoritative intent and policy,
selects a verification plan, executes eligible layers, records a common
evidence envelope, invalidates stale evidence when the change moves, and
produces both a machine-readable synthesis and a business-facing review
package. The coordinator is a proposed component name `[inferred]`; LID may
rename it.

### Authority and interpretation

The source of authority is ordered and explicit:

1. approved feature intent and its linked RDR/LID artifacts, when present;
2. project and account policy, including quality gates and verification settings;
3. the concrete change identity (repository, base/head or commit, run, and
   applicable environment); and
4. layer results and human decisions.

Human approval, an exception, or an AI interpretation must never be silently
promoted into source authority. Conflicts are surfaced as `blocked` or
`needs_review`, with the conflicting references in evidence.

### Nine verification layers `[inferred taxonomy]`

The initial taxonomy is deliberately an add-on over existing capabilities;
availability may be `implemented`, `unavailable`, `skipped_by_policy`, or
`blocked`.

1. **Intent/requirement conformance** — compare the change with approved
   intent, RDR/LID claims, and acceptance criteria.
2. **Structural/static checks** — deterministic repository, diff, schema, and
   policy checks that do not require an LLM judgment.
3. **Automated tests and CI evidence** — test commands and trusted CI results,
   including the existing TDD/readiness and quality-gate boundaries.
4. **Agent self-verification** — the run's declared checks, verification result,
   and artifacts, treated as evidence rather than authority.
5. **Independent automated review** — the staged find/verify/synthesize review
   path, with pinned-head and changed-line safeguards.
6. **Runtime/UI verification** — isolated browser or application interaction
   where the project configuration and capacity support it.
7. **Security and operational safety** — secrets, isolation, audit, resource,
   and deployment-safety checks available to the project.
8. **Human/business review** — a reviewer evaluates impact, exceptions,
   limitations, and whether the evidence answers the business question.
9. **Coverage and evidence synthesis** — calculate which acceptance claims and
   risk areas are covered, identify gaps/conflicts/staleness, and publish the
   final decision package.

The taxonomy is a proposed interpretation of the brief, not a claim that each
layer currently exists as a standalone service.

### Coordinator, layer, evidence, and synthesis interfaces

`LayeredVerification::Coordinator` `[inferred]` should receive an entry-path
request and return a run ID, selected plan, layer states, evidence references,
coverage, synthesis, and final disposition. Each layer adapter should expose a
small contract: applicability, required inputs, cost estimate, execution,
evidence output, and freshness key. A proposed common evidence envelope
`[inferred]` contains layer ID, claim/risk IDs, source authority, change
identity, status, timestamps, producer, artifact locators, redaction metadata,
limitations, and parent/derived evidence links.

The synthesis step must be deterministic about completeness, freshness,
conflicts, and policy gates. Any semantic summary must use `agent_harness` and
must cite the evidence IDs it interprets. It must not treat a missing layer as a
pass.

### Selection rubric and policy interaction

The coordinator selects layers using a versioned rubric `[inferred]` scoring:
change risk, affected surface, intent/acceptance coverage, project settings,
available evidence, estimated cost/latency, and required human authority. Policy
sets minimum layers and vetoes; the rubric may add layers or choose a cheaper
equivalent only when policy permits. Manual requests can ask for more evidence,
but cannot bypass a mandatory safety or approval gate without a recorded,
authorized exception.

### Change detection, invalidation, and repair

Every evidence item is bound to a change identity. A new head, changed relevant
files, changed approved intent, policy change, expired CI result, or changed
runtime configuration invalidates affected evidence. The coordinator retains
the invalidation reason, reuses unaffected evidence, reruns the smallest
affected layer set, and escalates when repair cannot restore required coverage.
The existing pinned-head and changed-line behavior is the model for this
contract, not a replacement for it.

### Business-facing review package

The package should answer: what changed, why it is authorized, which risks and
acceptance claims were checked, what evidence supports each conclusion, what
was not checked and why, what is stale or conflicting, estimated verification
cost, required approvals, exceptions, and the recommended disposition. It must
link to evidence without exposing secrets or unredacted repository/agent
content outside existing access controls.

### Cost and adoption principles

- Start with the smallest policy-sufficient plan and make selection explainable.
- Cache only evidence whose change identity and freshness policy still match.
- Prefer existing host capabilities before adding integrations.
- Keep optional external CI, scanners, deployment environments, and provider
  integrations behind adapters; initial capability must work with repository,
  run, review, quality-gate, approval, and artifact data already hosted by Paid.
- Measure cost, latency, coverage, reruns, stale evidence, and human override
  rates before expanding defaults. These are adoption signals, not supplied
  evidence that the outcome has been achieved.

## Alternatives Considered

### Keep verification as separate existing features

Rejected for this brief. It preserves today’s boundaries but cannot provide a
common selection rubric, traceability graph, change invalidation, or coverage
synthesis across the three requested entry paths.

### Run every available check for every change

Rejected. It ignores the brief’s cost/adoption principles, increases latency,
and makes optional integrations a de facto requirement.

### Let an LLM choose and certify everything

Rejected. It would make authority, policy, freshness, and safety decisions
opaque. Rails must enforce structural contracts and gates; `agent_harness` may
interpret bounded evidence where the selected layer needs semantic judgment.

### Build a new external verification platform first

Rejected for the initial capability. It would duplicate existing Paid services
and delay value. External scanners, CI providers, and deployment environments
remain optional adapters `[inferred]`.

## Trade-offs and Consequences

Positive consequences include a single traceable decision surface, less
duplicate verification, explicit evidence freshness, proportionate plans, and a
review package understandable to business reviewers. The design also makes
missing coverage visible instead of converting it into a pass.

Costs and risks include coordinator complexity, evidence retention and access
control, rerun latency, policy/rubric versioning, adapter maintenance, and the
possibility that stricter visibility initially produces more `needs_review`
outcomes. The nine-layer taxonomy and proposed interface names are hypotheses
that LID planning and human review may revise.

## Rollout Guard

This RDR changes runtime verification selection and dispositions, so it requires
a feature flag:

- **Flag**: `layered_verification_add_on`, added to
  `FeatureFlags::DEFINITIONS` by the Phase 1 implementation issue, with owner,
  intent, rollout plan, and cleanup criteria in the repository’s existing
  definition shape.
- **Default**: off. Runtime decisions read
  `FeatureFlags.enabled?(:layered_verification_add_on, project:)`.
- **Enablement surface**: per-tenant opt-in through the existing
  `tenant_settings.features` surface.
- **Rollback**: disable the flag; existing verification paths remain the
  source of runtime decisions and in-flight add-on runs are marked safely
  incomplete rather than treated as passed.
- **Cleanup**: remove the flag only after closeout verifies all mandatory
  acceptance criteria, evidence access controls, invalidation behavior, and
  representative scenarios, and records a safe-default decision.

Implementation issues must preserve this guard until closeout.

## Implementation Plan

Prerequisite: human review and acceptance of this docs-only RDR PR. A later
`lid_planning` run creates HLD/LLD/EARS artifacts; the issue tree uses the
following proposed IDs so implementation work is LID-aware from the start.

### Phase 1: Authority, contracts, and rollout guard

- Add the feature flag and safe default.
- Define entry-path request, change identity, authority precedence, layer
  result, evidence envelope, disposition, and redaction contracts.
- Define exception/approval records and policy/rubric versioning.
- `@spec LAYERED-VERIFY-001` `@spec LAYERED-VERIFY-002`

### Phase 2: Coordinator and selection rubric

- Implement the coordinator lifecycle and deterministic selection rubric.
- Integrate mandatory policy gates, budgets, manual escalation, and structured
  logging without replacing existing gate/approval authorities.
- `@spec LAYERED-VERIFY-003` `@spec LAYERED-VERIFY-004`

### Phase 3: Initial layer adapters and evidence graph

- Adapt the existing intent/conformance, structural/test/quality, agent-run,
  review, runtime/UI, and security/audit capabilities.
- Persist linked evidence and expose layer status, limitations, and failures.
- Keep optional external integrations out of the initial capability.
- `@spec LAYERED-VERIFY-005` `@spec LAYERED-VERIFY-006`

### Phase 4: Change impact, invalidation, and recovery

- Detect change and policy impact, invalidate affected evidence, reuse valid
  evidence, rerun the minimum affected layer set, and fail closed on unresolved
  staleness or conflicts.
- Test retries, head movement, partial results, and unavailable layers.
- `@spec LAYERED-VERIFY-007` `@spec LAYERED-VERIFY-008`

### Phase 5: Synthesis, business package, adoption, and optional adapters

- Produce the coverage matrix, machine synthesis, business-facing package,
  approval/exception presentation, cost/latency metrics, and representative
  end-to-end scenarios.
- Add optional integration adapters only after the initial host capability is
  stable and separately governed.
- `@spec LAYERED-VERIFY-009` `@spec LAYERED-VERIFY-010`

### Closeout

File a final RDR closeout/validation issue depending on Phases 1–5. It must
follow [`closeout-checklist.md`](closeout-checklist.md), compare shipped code,
tests, docs, and evidence against every acceptance criterion, record gaps as
focused child issues, and update this RDR and the README index.

## Validation

### Implementation acceptance criteria

1. Each of the three entry paths creates a traceable verification request
   bound to a change identity, approved authority, policy version, and feature
   flag state. (`LAYERED-VERIFY-001`)
2. The coordinator exposes the nine layer states and never reports `passed`
   when a mandatory layer is missing, stale, blocked, or failed. (`002`, `003`)
3. The rubric selects the smallest policy-sufficient plan, records the reasons,
   cost estimate, and policy overrides, and preserves human escalation.
   (`004`)
4. Initial adapters reuse the existing intent/conformance, quality/test,
   agent-run, review, runtime/UI, and security/audit capabilities and emit a
   common redacted evidence envelope with stable links. (`005`, `006`)
5. Evidence is invalidated when its bound change, relevant files, policy,
   intent, CI result, or runtime basis changes; repair reruns only affected
   layers and records the reason. (`007`, `008`)
6. Coverage synthesis maps evidence to acceptance/risk claims and identifies
   uncovered, conflicting, unavailable, and stale areas without treating them
   as passes. (`009`)
7. The business-facing package includes decision, rationale, evidence links,
   limitations, cost/latency, approvals, exceptions, and required next action,
   subject to existing authorization and redaction rules. (`009`)
8. The feature flag defaults off, can be disabled per tenant, and leaves the
   pre-feature verification decisions intact when disabled. (`001`)
9. Representative end-to-end scenarios cover agent-run, PR/review, and
   human/business entry, including a clean change, a failed mandatory check,
   stale evidence after a new head, an unavailable optional integration, and an
   authorized exception. (`010`)
10. Unit, integration, and system evidence demonstrates policy interaction,
    retries/idempotency, access control, auditability, cost accounting, and
    no-secret/no-untrusted-content leakage in the package or LLM inputs.
    (`002`, `006`, `008`, `010`)

### Validation approach and reconsideration conditions

Use contract/unit tests for selection, evidence, policy, invalidation, and
redaction; integration tests for each existing adapter; and end-to-end tests
for the representative scenarios above. Human review must inspect the package
for authority clarity and business usefulness. Reconsider this RDR if the
existing host capabilities cannot provide reliable change identity/evidence,
if mandatory policy cannot be enforced without bypasses, if adoption cost is
not proportionate to risk, or if the nine-layer taxonomy creates more
unresolved ambiguity than useful coverage.

The desired outcome is improved trust and proportionate review effort; it is not
declared achieved by passing these implementation tests. Outcome measurement is
part of the closeout evidence and later adoption review.
