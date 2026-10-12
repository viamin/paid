# RDR-075: General Maintenance Runs — Directed Audits and Recurring Repository Care

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-10-11
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Unassigned
- **Related RDRs**: [RDR-073](RDR-073-marketplace-tool-sidecars.md), [RDR-031](RDR-031-focused-agent-runs.md), [RDR-036](RDR-036-mutation-testing-for-ai-generated-tests.md), [RDR-046](RDR-046-polyglot-language-detection-and-test-execution.md), [RDR-054](RDR-054-prompt-assembly-service.md)
- **Blocked on**: RDR-073 implementation and final acceptance, tracked by [#4263](https://github.com/viamin/paid/issues/4263) and its [closeout #4268](https://github.com/viamin/paid/issues/4268)

## Dependencies

Depends on viamin/paid#4263.

This document may be drafted and reviewed while RDR-073 is in progress.
Implementation of RDR-075 remains blocked until RDR-073's implementation,
closeout, and umbrella final acceptance are complete, with no required gaps.
Acceptance of its design or completion of an individual phase does not release
this dependency. Future RDR-075 planning and implementation issues must carry
the explicit dependency above; a bare RDR reference does not block auto-pick.

## Problem Statement

Project owners need Paid to investigate repository health without first
writing a feature issue or attaching a pull request. Investigations can be
focused questions, broad audits, or recurring upkeep. A user should be able
to request, for example, an audit of parallel workflows A and B for potential
shared code extraction, with guidance about which behavior must remain
independent.

Paid needs a general maintenance capability for the projects it manages.
Its value is independent of whether a particular audit benefits Paid's own
repository. Unnecessary-code analysis is the initial use case, not the limit
of the capability. Future recipes can address dependency hygiene, stale
feature flags, documentation drift, and test quality.

The missing product behavior is a maintenance investigation with an explicit
objective, optional scope, user guidance, and a durable report. Existing
issue-creation or PR-creation goals do not express a successful investigation
that recommends no changes or leaves uncertainty unresolved.

## Context

### Existing components

- `AgentRun::GOALS` supports creation, review, issue analysis, and planning
  goals, but no general maintenance goal. Manual run creation already accepts
  `custom_prompt` in `Projects::AgentRunsController`.
- `Projects::DetectRepoProfile` and `Project#effective_repo_profile` supply
  detected languages, framework, and marker files. A project can contain
  multiple ecosystems.
- `PreCommitRequirements::Evaluate` executes configured checks and records
  blocking or advisory results. This is a validation integration point,
  rather than a complete maintenance investigation lifecycle.
- `ScheduledMutationSweepJob` and `MutationSweeps::Run` already provide
  opted-in periodic Ruby sweeps using containers and quality metrics. The
  sweep records a `create_pr` run even though its outcome is a metric.
- `Reviews::Verification::Pipeline` demonstrates pinned-revision candidate
  generation, verification, deduplication, and publication. Its pilot path
  runs without a container; maintenance tool execution cannot be assumed
  to work there without an explicit evidence-collection integration.

### Ownership boundary with RDR-073

[RDR-073](RDR-073-marketplace-tool-sidecars.md) owns marketplace tool
attachments, rule-based matching, per-run sidecar provisioning, hardening,
and cleanup. It proposes language, repository-file, and issue-label conditions
alongside existing task-text conditions.

This RDR owns maintenance objectives, investigation scope, reports, recurring
triggers, and transitions to repair work. It consumes the completed RDR-073
attachment lifecycle rather than creating a competing tool marketplace,
matching engine, or provisioning system. Matching must work for manual runs
without an issue; absent issue labels cannot prevent language or explicit
attachment selection from working.

## Research Findings

Source inspection of the components above establishes reusable execution,
configuration, and review patterns. It does not establish audit accuracy or
the suitability of any particular analyzer for blocking changes.

- [Exhale](https://github.com/tools4imps/exhale-ruby) documents Ruby/ERB
  structural duplication analysis, cognitive-complexity regression checks,
  structured output, merge-base comparisons, and reasoned exceptions with
  stale-clause checks. It does not prove code is unused and cannot detect
  every duplication of intent expressed through different structures.
- [Knip](https://knip.dev/) detects unused JavaScript/TypeScript files,
  exports, and dependencies using framework-aware entry points.
- [Debride](https://github.com/seattlerb/debride) identifies potentially
  uncalled Ruby methods. [Vulture](https://github.com/jendrikseipp/vulture)
  identifies unused Python code and documents dynamic-use false positives.
- [PMD CPD](https://github.com/pmd/pmd) provides duplication detection across
  multiple languages.

These are evaluation candidates, not approved deletion authorities. The
portable lessons are reproducible evidence, explicit exceptions, revision
context, and a distinction between findings and execution failures.

### Critical assumptions requiring validation

1. RDR-073's completed attachment contract can expose useful maintenance
   tools to issue-less runs. Verify this at the dependency handoff against
   shipped attachment, matching, and endpoint behavior.
2. Batch analyzers can analyze the pinned checkout and return evidence within
   the existing execution boundary. RDR-073's service-oriented image/port
   contract alone does not establish checkout access or batch invocation.
   Validate one native CLI analyzer and one sidecar interaction before
   finalizing the maintenance tool adapter design.
3. Repository intent, entry points, callers, and targeted validation can
   support actionable findings at reasonable cost. Compare prompt-only and
   tool-assisted investigations on pinned Ruby/Rails and JS/TS fixtures.
   Results select recipes and reporting policy, not whether maintenance
   exists as a product capability.

## Proposed Solution

### Maintenance run and recipe

Introduce a first-class maintenance goal within the existing `AgentRun`
lifecycle. A maintenance recipe supplies a reusable objective, investigation
instructions, applicable evidence collectors, and validation guidance. A
manual run may use a recipe or supply an original question; a catalog entry
is not required to investigate a user-directed maintenance question.

Each run captures the project, pinned repository revision, objective,
optional scope, user guidance, effective recipe version, selected tool
versions/configuration, and cost/time limits. Retries retain that context;
a new investigation against another revision is a new run.

The first delivery supports unnecessary-code investigations: unused code,
dependencies, duplication, complexity, unnecessary abstractions, and obsolete
behavior. Tool evidence identifies candidates; agents assess meaning through
`agent_harness`. Structural execution and policy enforcement remain in code.

### Manual focused investigation

Users can start maintenance from a project without an issue or PR, through
both the UI and an agent-accessible API/MCP surface. Free-text guidance is
supported, with optional paths or symbols to disambiguate the scope.

Illustrative request: "Audit parallel workflows A and B for potential shared
code extraction; preserve their independent retry and failure policies."

The agent resolves named targets before claiming coverage. Ambiguous or
missing targets produce an actionable clarification outcome, rather than
silently triggering a repository-wide scan. Reports identify the resolved
scope and any exclusions.

Scope bounds recommendations, not access to supporting evidence. The agent
may inspect callers, tests, framework entry points, and design documents
elsewhere to validate a claim. It must explain any recommendation requiring
changes beyond the requested scope; expanding the repair scope requires
explicit authorization.

### Evidence and reporting

The investigation collects available evidence, proposes candidates, verifies
them against code and intent, and produces a durable report tied to the run.
It does not require a separate agent session per stage; the implementation
must justify additional calls with measured improvements.

Each finding records its category, code locations/symbols, claim, supporting
evidence, known counterevidence, proposed action, validation plan, and
verification disposition. Raw tool confidence remains separate from the
agent's assessment. Similarity alone does not establish that code should be
shared; absence of static references or test coverage does not establish
that code can be deleted. Framework callbacks, reflection, external APIs,
intentional independence, and compatibility obligations must be considered.

A report distinguishes actionable findings, unresolved candidates, deliberate
exceptions, and coverage limitations. A completed investigation with no
findings is successful. Missing tools, parse failures, truncated analysis,
or unavailable services cannot be represented as a clean scan; partial
reports identify which checks actually completed. Cancellation and budget
exhaustion preserve collected evidence and visibly incomplete coverage.

Findings persist across runs with project- and recipe-scoped identity based
on the claim and affected symbols, not only shifting line numbers. Repeated
scans update occurrences rather than generating repeated repair work.
Dismissals retain reasons; materially changed evidence requires reassessment.
Repository-owned exceptions remain reviewable project intent, and stale
exceptions are reported rather than silently carried forever.

### Tool integration

Use RDR-073 marketplace attachments and matching to make tools available.
Maintenance adapters describe analyzer capabilities, invocation, input scope,
output parsing, exit-code meanings, version compatibility, and limitations.
They reference marketplace entries or existing in-container tools rather than
owning a second provisioning catalog.

Resolve capabilities per relevant package/ecosystem when a repository is
polyglot. Honor project configuration and manual selections. A language match
does not authorize a blocking gate or automatic fix. Invocation happens
inside the established isolated execution boundary; repository scripts and
analyzers do not execute on the control-plane host.

The dependency handoff must establish how batch tools access the pinned
checkout and return bounded artifacts. If this requires extending RDR-073,
record that upstream contract change explicitly; do not bypass its lifecycle
or require every command-line analyzer to become a network service.

### Recurring maintenance and repair

Project schedules capture the same recipe, scope, guidance, and limits as
manual runs. Each occurrence pins the then-current requested branch revision
and uses the existing queue, tenancy, authorization, and budget policies.
Schedules are opt-in, expose their timezone and next occurrence, avoid
overlapping equivalent runs, and bound retries and missed-occurrence catchup.
Disabling a schedule stops future dispatch; cancellation of an active run is
a separate explicit action.

Maintenance scans are report-only. A user can select findings to create
bounded repair issues or normal PR-creation runs, preserving source-report
links and revalidating evidence against the repair checkout. No scan directly
deletes source code or opens repair PRs as a side effect. Automatic repair is
outside the initial scope and requires a separately approved policy.

### PR integration

The evidence and verification components should be reusable for PR audits.
PR integration compares the actual base/head revisions and reports newly
introduced or worsened findings, with sufficient repository context for
verification. Existing debt belongs in maintenance reports. Findings feed
the existing review publication lifecycle rather than posting duplicate
reviews from an independent maintenance publisher.

Initial PR integration is advisory. Blocking is a later explicit project
policy supported by analyzer-specific accuracy and failure-handling evidence.

## Alternatives Considered

| Alternative | Benefit | Reason not selected |
|-------------|---------|---------------------|
| Custom prompts on existing creation goals | Small initial change | Cannot faithfully represent report-only success, recurring finding identity, or maintenance scope |
| Whole-repository scheduled scans only | Simple schedule model | Omits user-directed questions and focused manual investigations |
| Prompt-only maintenance | Works without analyzers | Retained as a supported execution path, but insufficient as the only evidence source |
| Independent maintenance tool catalog/provisioner | Dedicated control | Duplicates RDR-073 matching, attachment, hardening, and lifecycle responsibilities |
| Automatic cleanup during scans | Immediate changes | Combines investigation with repair authorization and encourages oversized changes |

## Trade-offs and Consequences

Maintenance becomes a reusable product workflow independent of feature
delivery. Focused questions can be investigated without enumerating every
file, and recurring audits retain findings rather than producing repetitive
noise. Tool evidence and semantic judgment complement each other.

The cost is a new run outcome contract, durable reports and finding identity,
scope handling, schedule configuration, and maintenance-specific UI/API
surfaces. Analyzer configuration and dynamic-language false positives require
ongoing attention. Separate scan and repair runs add a handoff but make the
requested investigation and authorized changes explicit.

Deduplication can hide changed problems if identity is too broad; evidence
revision and dismissal reassessment must be tested. Narrow scopes can create
false confidence; reports must disclose supporting inspection and coverage
gaps. Budgets bound investigation cost, and limits appear in the report.

## Rollout Guard

This draft is documentation only. Runtime implementation ships behind a
`maintenance_runs` feature flag, default off, with tenant opt-in through
`tenant_settings.features`. Phase 1 owns its registration in
`FeatureFlags::DEFINITIONS` and runtime checks through
`FeatureFlags.enabled?(:maintenance_runs, project:)` for UI/API admission
and scheduled dispatch. RDR-073's own guard remains authoritative for tools.

Rollback disables new maintenance admissions and scheduled dispatch without
deleting reports; active runs remain cancellable through their lifecycle.
Remove the rollout flag only after closeout verifies manual focused audits,
report outcomes, tool isolation, recurrence/deduplication, and UI/API parity.
Recurring schedules remain explicitly opt-in after rollout.

## Implementation Plan

1. **Prerequisites and LID planning:** RDR-073 final acceptance, acceptance of
   this recommendation, and validation of the tool handoff assumptions.
   Update the HLD and create the maintenance LLD/EARS segment and arrow
   references before implementation. Resolve storage/API contracts there.
2. **Manual maintenance lifecycle:** maintenance goal, admission and rollout
   guard, objective/scope/guidance snapshots, report-only execution and
   successful empty outcomes. Provide UI and API/MCP entry points together.
3. **Reports and findings:** evidence artifacts, coverage states, finding
   occurrence identity, reasoned dismissals, and report inspection surfaces.
4. **Tool-assisted recipes:** integrate completed RDR-073 attachments;
   evaluate Ruby/Rails and JS/TS analyzers; support prompt-only investigation
   where no suitable tool exists. Record version/configuration provenance.
5. **Repair handoff:** selected findings become bounded issues or PR runs
   through existing authorized pathways, with revision revalidation.
6. **Recurring maintenance:** project schedules, overlap prevention, bounded
   retry/catchup, budgets, disable/cancel behavior, and recurring summaries.
7. **Advisory PR integration:** reuse evidence in the existing review path;
   preserve pinned revisions, scope, verification, and publication policy.
8. **Closeout and final acceptance:** audit each criterion and desired user
   outcome, record gaps, reconcile RDR/index status, and decide guard removal
   using the [closeout checklist](closeout-checklist.md).

Create implementation issues after the design is accepted. The maintenance
umbrella and planning issue must explicitly depend on viamin/paid#4263;
child issues must carry the appropriate phase dependencies. Closeout tracks
the umbrella with non-closing language; only its final audit closes it.

## Validation

Use behavior tests and failing-first EARS-linked implementation tests. A
documentation-only draft does not require application tests.

Acceptance scenarios:

1. A user starts an issue-less manual scan asking about workflows A and B.
   The run resolves those targets, retains guidance, inspects supporting
   callers, and reports within the requested recommendation scope.
2. An ambiguous target produces an actionable clarification outcome without
   silently broadening the scan. A broad audit explicitly records broad scope.
3. Deliberately independent workflows and dynamically invoked framework code
   are not recommended for consolidation/deletion solely from analyzer output.
4. A supported tool attaches through RDR-073, analyzes the pinned checkout
   within the isolated boundary, and records version/configuration evidence.
   An issue-less polyglot scan can select relevant tools without issue labels.
5. A clean scan completes successfully. A parse error, unavailable dependency,
   timeout, or budget exhaustion produces visible incomplete coverage, never
   a false clean result. Source files remain unchanged by the scan.
6. Repeating a scan updates finding occurrences without duplicate repair work.
   Changed supporting evidence prompts reassessment of a dismissed finding.
7. Selected findings create bounded repair work linked to the report; a changed
   target revision requires revalidation before applying the recommendation.
8. Recurring runs obey tenant access, budgets, non-overlap and bounded catchup.
   Disabling schedules prevents new dispatch and preserves prior reports.
9. UI and API/MCP users can start, inspect, cancel, and select repair work with
   equivalent authorization. Maintenance is not admitted while its guard is off.
10. PR audits distinguish new regressions from existing debt and publish through
    the existing review path without duplicate reviews or stale-head findings.

The desired user outcome is that project owners can ask a focused maintenance
question or configure recurring care, receive a useful cited report, and choose
bounded follow-up work. Evaluate this on projects beyond Paid itself. Measure
actionable findings, false positives, unresolved coverage, latency, token/tool
cost, repeated-finding noise, and repair review outcomes. These measurements
guide recipe selection and later blocking policies; they do not gate the
existence of the general maintenance capability.

## Open Questions Before Finalization

- Which batch invocation/checkout-access contract does completed RDR-073
  expose, and which maintenance adapter extensions remain necessary?
- What report/finding schema and API responses best fit existing run and
  knowledge artifacts without treating reports as PR outputs or quality scores?
- Which initial analyzer versions and project configurations produce useful
  evidence, and how should unresolved user questions be resumed or rerun?
- Should existing scheduled mutation sweeps migrate into maintenance recipes?
  Keep their current behavior until an explicit migration is designed.
