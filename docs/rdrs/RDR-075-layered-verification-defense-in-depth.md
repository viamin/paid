# RDR-075: Layered Verification Add-On (Defense in Depth) for Paid

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-10-12
- **Status**: Draft
- **Type**: Architecture + Process
- **Priority**: P1 `[inferred — not supplied by the feature brief]`
- **Related RDRs**: [RDR-021](RDR-021-knowledge-base.md) (Knowledge Base Architecture), [RDR-031](RDR-031-focused-agent-runs.md) (Focused Agent Runs), [RDR-042](RDR-042-change-intent-records.md) (Change Intent Records), [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs), [RDR-053](RDR-053-new-feature-creation.md) (New Feature Creation), [RDR-056](RDR-056-strict-test-driven-development-mode.md) (TDD Modes), [RDR-061](RDR-061-infrastructure-safety-and-audit.md) (Infrastructure Safety), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md) (Feature Intent and Approval Lifecycle), [RDR-067](RDR-067-approved-intent-conformance.md) (Approved Intent Conformance), [RDR-070](RDR-070-facet-confidence-and-clarification.md) (Facet Confidence), [RDR-071](RDR-071-confidence-driven-issue-delivery.md) (Confidence-Driven Delivery), [RDR-073](RDR-073-marketplace-tool-sidecars.md) (Marketplace Tool Sidecars), [RDR-074](RDR-074-project-readiness.md) (Project Readiness)
- **Related Intent**: `docs/high-level-design.md`, `docs/intent/auto-merge-strategy/`, `docs/intent/operator-inbox/`, `docs/intent/feature-approval/`, `docs/intent/approved-intent-conformance/`, `docs/intent/issue-enhancement/`, `docs/intent/tdd-mode/`, `docs/intent/tdd-test-review-prs/`, plus a new `docs/intent/layered-verification/` segment to be authored by `lid_planning` after acceptance
- **Related Issues**: implementation issue tree filed by the creating run (one epic, one issue per phase/capability, one closeout issue); numbers recorded in the epic body

## Problem Statement

Paid already orchestrates agents that turn business intent into PRs, but it
does not maintain correspondence between the **authoritative business intent**
that justified a change and the **implemented behavior** that shipped. A
completed feature PR can satisfy every existing PR review, auto-merge,
knowledge-artifact, and conformance-with-approved-design check, yet still
fail to honor a business obligation that was never written down, never
articulated to the implementing agent, or only lived in conversation that
later evaporated. When that gap appears, the human discovers it after merge,
often during an audit or an incident, with no actionable evidence trail.

The selected framing — recorded as user-confirmed in the feature brief — is
that layered verifications of different levels create a "defense in depth"
for linking business logic and developer intent to the final code
implementation. The add-on treats business intent as the authoritative
source and uses multiple complementary verification layers — human review,
agent judgment, executable checks — each suited to different obligations and
different failure modes. Coverage is reported by business obligation rather
than by tool, and changes to either intent or implementation invalidate
downstream correspondence evidence without necessarily requiring edits to
every linked artifact.

The desired outcome is a single coherent RDR that defines (a) the host
framework's existing capabilities and the smallest missing components
required for the add-on, (b) the coordinator, layer interfaces, evidence
representation, and synthesis behavior, (c) source authority, review,
approval, and exception handling, (d) the verification-selection rubric and
its interaction with mandatory host policies, (e) change-impact detection,
evidence invalidation, and recovery from interrupted work, (f)
representative end-to-end evaluation scenarios for the supported entry
paths, (g) the initial usable capability separated from optional
integrations, and (h) the engineering decisions still needed.

## Context

### Observations supplied by the brief

The brief provides the following framing; this section preserves the brief's
distinctions verbatim and labels them as supplied observations rather than
facts Paid has independently verified.

- Paid is the host development framework — it already provides agent runs,
  PR review, the knowledge base, configuration profiles, and issue tracking
  as substrate. The add-on does not replace those; it composes with them.
- The user-supplied brief defines an add-on that maintains correspondence
  between authoritative business intent and implemented behavior through
  complementary layers of human review, agent judgment, and executable
  checks.
- The brief explicitly distinguishes **linkage** (references connecting
  artifacts, e.g., an issue points at a code location) from **conformance**
  (behavioral agreement, e.g., that code location actually satisfies the
  obligation). Both are needed; conflating them obscures the failure mode
  each layer is meant to detect.
- Reporting is by business obligation rather than by tool. Coverage
  expressed as "we ran X checks" is not the goal; the goal is "this
  obligation is verified by these checks against this implementation state,
  and this obligation is not."
- The framing as "defense in depth": layered verifications of different
  levels create a defense in depth for linking business logic and developer
  intent to the final code implementation.

Supplied evidence/references for the RDR-075 planner:

- User-supplied planner brief, parts 1 and 2, pasted verbatim into this
  prompt. Covers: purpose, intended outcome, authority and interpretation,
  three supported entry paths, overall architecture (coordination + layer
  capabilities + coverage synthesis), nine verification layers, the
  business-facing review package, the verification-selection rubric (six
  risk categories), evidence and traceability requirements, change detection
  and repair (four finding categories), coverage synthesis rules, cost and
  adoption principles, ten acceptance demonstrations, and the requested
  planner output.

### Selected framing (user-confirmed)

> Layered verifications of different levels create a "defense in depth" for
> linking business logic and developer intent to the final code
> implementation. The add-on treats business intent as the authoritative
> source and uses multiple complementary verification layers — human review,
> agent judgment, executable checks — each suited to different obligations
> and failure modes. Coverage is reported by business obligation rather
> than by tool, and changes to either intent or implementation invalidate
> downstream correspondence evidence without necessarily requiring edits to
> every linked artifact.

The brief marks this `selected_framing_confirmed: true`. Remaining material
framings (treat the add-on as an overlay rather than a new product; compose
with existing Paid substrate rather than replace it; host the add-on inside
Paid without building a separate service; do not require one agent per
layer) are surfaced in **Alternatives Considered**, not promoted to
user-confirmed choices.

### Affected stakeholders (supplied by the brief)

- Business owners who carry obligations and want auditable evidence that the
  implementation honors them.
- Engineers and reviewers who need a single source for "what does this code
  claim to satisfy, who verified that, and where is the evidence."
- Auditors and compliance reviewers who want obligation-by-obligation
  coverage and a lineage from intent to commit.
- Operators and platform teams who want predictable cost and adoption
  paths.

### Existing Paid host capabilities the add-on composes with

- Agent run goals, container provisioning, and lifecycle (`AgentRun`,
  `Activities::RunAgentActivity`,
  `docs/rdrs/RDR-002-workflow-orchestration.md`,
  `RDR-031-focused-agent-runs.md`). The add-on is one extra use of the same
  run infrastructure; it does not provision a second agent fleet.
- Repository-native design substrate: HLD/LLD/EARS via LID
  (`Lid::InjectIntoPrompt`, `Lid::PlanningContract`,
  `app/services/lid/planning_contract.rb`,
  `docs/rdrs/RDR-051-lid-aware-agent-runs.md`) and RDRs under
  `docs/rdrs/`. Repository documents remain the source of design content
  for the add-on's authoritative intent layer.
- Feature Intent workflow and amendment lifecycle
  (`FeatureIntent`, `DesignAmendments::EvaluateImpact`,
  `FeatureIntents::RunAdmission`,
  `docs/rdrs/RDR-066-feature-intent-approval-lifecycle.md`,
  `RDR-067-approved-intent-conformance.md`). The add-on's obligation
  records are reusable artifacts that can be linked from a Feature Intent
  and carried into the existing Inbox and merge-guard surfaces.
- Knowledge base and Change Intent Records
  (`KnowledgeArtifact`/`KnowledgeChunk`, `ChangeIntent`,
  `docs/rdrs/RDR-021-knowledge-base.md`,
  `RDR-042-change-intent-records.md`). Obligations carry directional intent
  and can be searched and surfaced alongside existing artifact types
  without introducing a parallel pipeline.
- TDD modes and human test review
  (`Tdd::Mode`, `Tdd::ReturnToTestReview`,
  `docs/rdrs/RDR-056-strict-test-driven-development-mode.md`). The
  behavioral-test and human-test-review layers are reused rather than
  recreated.
- Project readiness and configuration profiles
  (`Projects::Readiness`, configuration profiles,
  `docs/rdrs/RDR-044-configuration-profiles-chat.md`,
  `RDR-074-project-readiness.md`). The add-on's verifier selection can read
  the same profile and readiness decisions the run path already reads.
- Inbox and operator inbox surfaces
  (`Inbox::Queue`, `Inbox::IntentConformance`,
  `docs/rdrs/RDR-066-feature-intent-approval-lifecycle.md`). Verifier
  findings land on the same Inbox the existing approval and conformance
  flows already use; no parallel review surface is introduced.
- Audit-event substrate
  (`ExecutionAuditEvent`,
  `app/services/execution_audit_events/lifecycle.rb`,
  `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md`). Verifier
  scheduling, completion, and invalidation events are recorded through the
  same append-only stream; no parallel audit log.

### Capabilities the brief calls out and Paid does not yet have

- An **obligation record** (distinct from `ChangeIntent`): a typed artifact
  scoped to a business obligation, with linkage, freshness, owners, and
  evidence references. `ChangeIntent` captures directional intent for a
  particular change; obligations persist across many changes and must keep
  fresh evidence against the implementation.
- A **verifier contract**: a uniform interface a layer can declare, with
  inputs (obligation + implementation artifacts), outputs (findings,
  evidence references), and cost bounds. Layers built today in Paid (PR
  review, conformance review, behavioral tests) are heterogeneous in
  capability, scheduling, and output; the add-on needs a single verifier
  representation so the coordinator can plan and synthesize uniformly.
- A **coordinator**: a service that reads the obligation set, the
  verifier-selection rubric, and project readiness, and schedules the
  verifiers it judges necessary, collects evidence, and synthesizes an
  obligation-by-obligation coverage report. The brief is explicit that
  this is a *coordinator*, not a "one agent per layer" orchestration — a
  single agent can drive multiple verifiers, and not every obligation
  needs every layer on every run.
- A **selection rubric** codifying, for each of six risk categories the
  brief names (correctness, completeness, safety/security, performance,
  consistency/intent fidelity, and provenance/reproducibility — names
  recorded verbatim from the brief, to be elaborated in the LLD), which
  layers contribute evidence and at what depth. The rubric is data, not a
  new agent; it lives alongside configuration profiles and reads from
  them.
- **Coverage synthesis by obligation**: a report shape that answers "is
  this obligation satisfied?" for each obligation on each product
  surface, with the contributing verifiers, evidence references, and
  freshness state. Aggregation across obligations is computed, not
  declared.
- **Evidence invalidation on change**: a routine that, when intent or
  implementation changes, marks the affected evidence as stale without
  requiring edits to every linked artifact, and re-runs only the layers
  whose evidence was invalidated.
- **Change-impact categorization into four finding classes** the brief
  names (preserved verbatim, to be elaborated in the LLD): missing
  evidence (a layer was skipped, lost, or never produced), stale evidence
  (the implementation moved), drifted obligation (the intent changed),
  failed verification (the layer ran and produced a negative result). The
  repair workflow differs by class — the system does not invent a single
  uniform "redo everything" response.

## Research Findings

Investigation performed 2026-10-12 against `main` (post RDR-074). The
findings below trace to specific files or documents and are the
factual basis for the host-capabilities section above.

1. **The substrate is diverse but uncoordinated.** `AgentRun::GOALS`
   enumerates distinct run goals (`create_pr`, `create_issue`,
   `create_feature`, `review`, `enhance_issue`, `analyze_issue`,
   `lid_planning`) in `app/models/agent_run.rb`; each has its own
   prompt builder, repo-cloned behavior, and completion semantics. There
   is no general-purpose "verifier" goal today; review today is a PR
   review, not an obligation review.
2. **LID already provides repository-native design contract.**
   `Lid::PlanningContract` (`app/services/lid/planning_contract.rb`)
   gates the docs-only Planning PR on HLD/LLD/EARS structural
   completeness. `docs/intent/` is the canonical artifact store; the
   add-on's obligation contracts belong there as a new segment
   `docs/intent/layered-verification/`, not as a parallel substrate.
3. **Feature Intent already links intent to execution.** `FeatureIntent`
   (`app/models/feature_intent.rb`) and the lifecycle services
   (`FeatureIntents::ApprovalReadiness`,
   `FeatureIntents::MarkApproved`,
   `FeatureIntents::RunAdmission`,
   `FeatureIntents::ReconcileDesignPullRequest`,
   `FeatureIntents::Release`,
   `FeatureIntents::AttachFromAgentRun`) plus
   `DesignAmendments::EvaluateImpact`
   (`app/services/design_amendments/`) provide the approval-revision and
   revision-impact machinery. Obligations can reference an approved
   revision without inventing a separate authorization record.
4. **PR conformance is now a first-class guard.** `IntentConformance::VerifyAtMerge`
   (`app/services/intent_conformance/verify_at_merge.rb`) and the
   Inbox lane (`Inbox::IntentConformance`) gate feature-PR merges against
   the current PR head and approved design revision. The brief's
   "implementation/specification conformance" layer reuses this — the
   add-on is not a separate merge guard but a wider obligation graph
   that this guard already covers for one obligation type.
5. **Mutation testing is operational.** `Mutant` integration
   (`spec/services/mutation_sweeps/`,
   `docs/rdrs/RDR-036-mutation-testing-for-ai-generated-tests.md`)
   gives the add-on's "mutation" verification layer an existing,
   project-aware runner to compose with rather than rebuild.
6. **Behavioral tests and TDD review are configurable.** `Tdd::Mode`
   states (`off`/`non_strict`/`strict`,
   `docs/rdrs/RDR-056-strict-test-driven-development-mode.md`) and
   `Projects::Readiness`
   (`app/services/projects/readiness.rb`,
   `docs/rdrs/RDR-074-project-readiness.md`) already expose the
   runnable-test-command and CI-capable-repository checks the brief's
   "behavioral testing" and "formal verification" layers need.
7. **Knowledge artifact pipeline accepts new types.** `KnowledgeArtifact`
   carries an `artifact_type` column; `ChangeIntent` is already an
   example of adding a typed artifact without new ingestion
   infrastructure (`docs/rdrs/RDR-042-change-intent-records.md`). The
   add-on's obligation records follow the same pattern, with a distinct
   `artifact_type: "business_obligation"` so they are not confused with
   directional intent.
8. **Inbox and operator inbox already compose typed items.**
   `Inbox::Queue` (`app/services/inbox/queue.rb`) composes
   clarifying-question, plan-review, merge-approval, action-required,
   and intent-conformance entries. The brief's four-class finding
   synthesis is naturally a typed lane or composite; reusing
   `Inbox::IntentConformance` as the precedent keeps new
   `Inbox::VerificationFinding` and `Inbox::CoverageStatus` items
   legible and actionable from the same operator surface.
9. **Audit event stream is append-only and secret-safe.**
   `ExecutionAuditEvent`
   (`app/models/execution_audit_event.rb`,
   `app/services/execution_audit_events/lifecycle.rb`,
   `docs/rdrs/RDR-061-infrastructure-safety-and-audit.md`) records
   who caused execution infrastructure to exist with what authority.
   Verifier-scheduling, completion, and invalidation events extend the
   same stream; the add-on does not introduce a second audit log.
10. **There is no "obligations to verifiers" surface today.** Searched
    `app/`, `app/services/`, and `docs/rdrs/` for obligation / verifier /
    coverage-graph combinations. The closest existing concept is
    `FeatureIntent` (authorization record), `DesignAmendment` (revision
    impact), and `IntentConformance` (current-head/current-design guard
    for the conformance layer only). The data model and coordinator
    proposed below are net-new but composable with every one of the
    above.

## Proposed Solution

### Approach

Deliver the add-on as a **coordinator** that reads an obligation graph and
selects, schedules, and synthesizes a layered set of verifiers, while
keeping obligation, linkage, evidence, and verifier definitions as
**data** with their own contracts. Paid remains the host; the add-on uses
its container and prompt infrastructure, knowledge pipeline, feature
workflow, audit log, and Inbox surface; it does not introduce a second
agent fleet or a parallel audit log.

### Core components

#### 1. Source authority for business intent

Authoritative intent is the obligation record, not the conversation or
the diff. An `obligation` is a typed artifact that names a business
obligation, names the product surface it constrains, lists owners and
reviewers, points at design and code artifacts that *reference* it
(linkage), and binds the evidence links a verifier is expected to
produce (conformance, populated by verifiers, not authors).

Obligations live in a new `business_obligations` table, mirrored into
the knowledge pipeline as `artifact_type: "business_obligation"`
(`KnowledgeArtifact`). `ChangeIntent` continues to capture *directional
intent for a particular change*; obligations capture *standing intent
that spans many changes*. They are distinct artifact types by design.
The LLD decides whether a SQL view or a polymorphic association links
them for traceability between a directional change and the obligations
it satisfies.

Obligations are exported to the project repository as `docs/obligations/<slug>.md`
following the RDR's HLD format, so reviewers find them where they find
HLD/LLD/EARS today. The repository document is the human-facing form;
the database row is the machine-facing form. Drift between the two
fails closed the same way LID drift detection does today.

#### 2. Coordinator

The coordinator is a single service that reads:

- the obligation set (project-scoped, freshness-stamped);
- the verifier-selection rubric (six risk categories × nine layers,
  codified as data, not encoded in prompt instructions);
- project readiness (`Projects::Readiness`) and configuration
  profile state (TDD mode, auto-merge mode, market posture);
- existing evidence freshness (last verification timestamp, last
  implementation SHA referenced); and

emits:

- a **verifier plan** that names the layers to run, their scope
  (which obligations, which implementation artifacts), their cost
  bounds, and the order in which they run so cheap, deterministic
  checks precede expensive, semantic ones;
- an obligation-by-obligation **coverage record** with the contributing
  verifiers, evidence references, freshness state, and outstanding
  finding class; and
- an **invalidation report** when intent or implementation changes,
  listing which evidence is now stale and which layers must re-run.

The coordinator is **not an agent**. It is a deterministic service that
delegates semantic judgments to the existing agent runs (one per layer
slot it opens, not one per layer) and to the operations it already
invokes today. The same run container and the same
`agent_harness` provider surface execute the verifier plans; only the
prompt, the contract, and the result shape change.

#### 3. Layer contract

Every layer — human review, agent judgment, executable check, mutation,
formal verification, behavioral test, conformance, semantic audit —
declares the same contract:

| Field | Meaning |
|---|---|
| `kind` | one of the nine layer names the brief supplies |
| `applicability_predicate` | data expression over obligation + project state |
| `inputs` | obligations, file paths, commits, ranges |
| `outputs` | findings, evidence references, confidence |
| `cost_bound` | token/wall/cost ceiling per obligation or per surface |
| `evidence_format` | what an evidence row must contain for synthesis |
| `invalidations` | which intent or implementation changes invalidate this evidence |
| `access` | which obligations this layer can read/write (least-privilege per the brief's "cost and adoption principles") |

A layer's contract is a **Ruby class** that implements an interface, plus
**JSON-Schema** for its persisted result. Implementing nine concrete
layers is incremental; the contract is the enabler. Phase 1 ships the
contract and the cheapest, deterministic layers; later phases add
expensive semantic layers per the selection rubric.

#### 4. Selection rubric

Codified in `app/services/verification/rubric.rb` (name tentative). For
each of the six risk categories the brief names (verbatim from the brief,
to be elaborated in the LLD), the rubric returns the set of layers whose
applicability predicate matches the obligation + project state. The
brief's rule that the rubric must produce materially different
recommendations for materially different obligations is enforced
structurally: a rubric evaluation that returns the same layer set for
two obligations that differ in the six categories is a test failure,
not a runtime-only check.

The rubric reads from existing configuration profiles and project
readiness state rather than introducing a new settings model. Existing
project controls (TDD mode, auto-merge mode, integration posture) feed
the rubric as inputs; the rubric does not override them.

The brief explicitly distinguishes **mandatory** host policies (CI,
security, code quality, branch protection — operations Paid must run
regardless of the add-on) from the rubric's optional layer
recommendations. Mandatory host policies apply unconditionally and
their evidence contributes to obligation coverage; the rubric selects
additional layers whose costs are bounded by the operator's
configuration.

#### 5. Evidence representation and invalidation

Evidence is **content-addressed**, not Git-state-addressed: an evidence
record carries the obligation id, the layer kind, the specific claim the
evidence supports, the verifier identity, the implementation commit the
verifier evaluated, the result, and a content hash of the inputs the
verifier saw. Synthesis asks "what evidence references this claim on
this obligation as of now?" — not "did this implementation point at this
obligation at some point?"

When intent changes (a new approved revision, an obligation rewritten,
a superseded obligation record), the coordinator diffs the obligation
graph and marks only the evidence whose claims no longer match as
stale. When implementation changes (a commit lands on the branch the
verifier evaluated), evidence keyed on the commit is stale; evidence
keyed on a stable product surface that the commit did not change
remains valid. Cost is bounded by the diff size, not by the obligation
graph.

#### 6. Three supported entry paths

- **Design entry**. The user is designing a feature that touches an
  existing obligation or creates one. Obligations surface in the
  existing `create_feature` flow via `Lid::InjectIntoPrompt` and the
  Feature Intent workflow. The add-on does not add a new chat lane; it
  composes with the existing chat and Feature Intent surfaces.
- **Audit entry**. The user wants to know "are we currently meeting
  obligation X?" Audit is a coordinator invocation that runs the
  relevant subset of verifiers from scratch and produces a coverage
  report. It is the same coordinator; the entry point is a UI surface
  or a chat command ("audit obligations") rather than an agent run
  that ships code.
- **Bootstrap entry**. A new project has no obligations yet. The
  coordinator proposes an initial obligation set from the project's
  domain (the brief explicitly allows this), the user accepts / edits /
  rejects, and the resulting set is committed alongside the first
  design PR. The bootstrapper is prompted-agent, not autonomous; it
  asks before it writes.

Each entry path uses the same obligation store, the same rubric, the
same layers, and the same synthesis report. They differ only in which
verifier plans they generate.

#### 7. Business-facing review package

The brief names a "business-facing review package" as one deliverable.
Concretely, this is an obligation-by-obligation coverage report that a
non-engineer stakeholder can read: which obligations are met, which are
not, why each one is not, what evidence the package relies on, and who
owns the next step. It is the same data the coordinator emits,
rendered for the audience named in the brief. The LLD settles whether
the package is a static MD/HTML rendering or an interactive Inbox view;
both are acceptable.

#### 8. Four-class finding synthesis

The brief names four finding classes (preserved verbatim here for
implementation inheritance): missing evidence, stale evidence, drifted
obligation, failed verification. The coordinator publishes these as
typed Inbox items with class-distinct actions:

| Class | Inbox action | Repair shape |
|---|---|---|
| Missing evidence | "Verifiers skipped: name them; ask coordinator to schedule." | Re-run the named verifier. |
| Stale evidence | "Implementation moved since this evidence ran." | Re-run only the layers whose evidence is invalidated. |
| Drifted obligation | "Intent changed; evidence links need to be revalidated." | Confirm or revise the obligation; re-run adoption. |
| Failed verification | "Verifier produced a negative result on the current state." | Surface the verifier finding; do not silently re-run with a different prompt. |

The brief's "no single uniform redo" rule is structural: each class has
a distinct action and a distinct owner. A failed-verification finding
cannot be cleared by re-running the same layer with a different prompt;
that would be hiding a real failure.

#### 9. Engineering decisions still needed

The brief leaves the following to the LLD; this RDR records them as
explicit open questions for the implementer and signals them in the
PR description so a human reviewer can answer them at the design step
rather than during implementation:

- The exact nine-layer taxonomy is supplied by the brief; the LLD
  publishes the canonical kind names and the slot taxonomy (each layer
  has one contract; multiple concrete verifiers may implement it).
- The six risk categories the rubric reads are supplied by the brief
  (correctness, completeness, safety/security, performance, consistency
  / intent fidelity, and provenance/reproducibility — names preserved
  verbatim); the LLD publishes the project's exact field names and the
  minimum criteria each category requires.
- The "least-privilege per obligation" rule in the layer `access` field
  is supplied by the brief as a direction. The LLD chooses the
  representation: tier (read-only mirror, redacted secret, surface-only)
  versus a per-obligation ACL.
- The review package's rendering audience (markdown, Inbox lane, or
  both) is supplied by the brief as a desired artifact; the LLD picks
  one primary surface and one secondary.

### Decision rationale

1. **Coordinator, not a multi-agent pipeline.** The brief explicitly
   requires this: layering without an agent per layer. The coordinator
   uses existing `agent_harness` runs for the layers it opens; one run
   can drive multiple verifier slots; not every obligation needs every
   layer.
2. **Obligations are data, not agents.** An obligation record is a
   typed artifact that survives the lifecycle of any single change. It
   is the only place where the rubric's notion of "this obligation"
   lives, so the coordinator, the audit, and the review package can
   all reference it.
3. **Layer contract over per-layer code paths.** Each layer is a
   Ruby class implementing one interface, not a per-layer hand-rolled
   service. This is the same pattern as `Automation::Strategies::*`
   (RDR-023): strategy is data, registration is one place, tests are
   uniform.
4. **Compose with mandatory host policies rather than replace them.**
   CI, security scanners, code review, branch protection, and
   conformance-with-approved-design remain unconditional. The rubric
   adds *additional* layers whose costs are bounded; it does not
   override the host.
5. **Evidence is content-addressed so invalidation is targeted.** A
   commit-keyed evidence record becomes stale on the next commit; an
   obligation-keyed record with claim-level addressing becomes stale
   only on the specific claim that changed. The brief's "don't redo
   everything" rule is structural, not policed.
6. **Three entry paths share the same coordinator.** Differing only in
   which verifier plans they generate keeps the design from
   splintering. The brief explicitly authorizes this.
7. **Bootstrap is human-in-the-loop by default.** The brief's cost
   and adoption principles rule out autonomous obligation minting;
   bootstrap prompts, the user accepts/edits/rejects, and the resulting
   set is committed like any other design artifact.

## Alternatives Considered

### Alternative A: Build a separate verification service outside Paid

**Description**: Stand up a new product with its own UI, persistence,
auth, and agent fleet. Pay would integrate via webhooks and APIs.

**Pros**: Clean separation of concerns; the verification product could
be sold independently; no obligation to honor Paid's existing
constraints.

**Cons**: Re-implements the substrate the brief observes is already
present (agent runs, prompts, knowledge pipeline, feature workflow,
audit, Inbox). The brief's first reconsideration condition is explicit
on this point: "If the planner finds that Paid cannot serve as host
without building a separate service, the add-on may need to be
re-scoped as a standalone product." Phase 1 is structured to test that
re-scoping decision by attempting to deliver the host capability inside
Paid first; the re-scoping decision is a live gate, not a starting
assumption.

**Reason for rejection (for now)**: Phase 1 is the host-internal
implementation; standalone is a Phase 4 reconsideration, not a Phase 1
choice.

### Alternative B: One verifier per layer (an agent per layer, instead of a coordinator)

**Description**: Spawn a distinct agent for each layer; let agents
coordinate themselves via messages; collect their results.

**Pros**: Easy to add a new layer (just add another agent type);
agents can self-schedule.

**Cons**: The brief explicitly rejects this. "Without requiring one
agent per layer" is a stated requirement. Doubles agent overhead per
verification cycle; obscures cost bounds because each agent sees its
own piece of the obligation graph; fails the brief's least-privilege
rule because each agent has its own context window.

**Reason for rejection**: Contradicts a stated requirement.

### Alternative C: Tool-indexed coverage instead of obligation-indexed coverage

**Description**: Group evidence by the tool that produced it ("the
mutation suite passed"; "the conformance review passed") and present
that as the coverage story.

**Pros**: Simpler data model; matches how most CI dashboards work; no
new artifact type.

**Cons**: The brief explicitly rules this out: "Reporting by business
obligation rather than by tool." Tool-indexed reporting is exactly the
gap the user wants to close.

**Reason for rejection**: Contradicts the stated framing.

### Alternative D: Force obligation edits when implementation changes

**Description**: When a commit moves an artifact the obligation points
at, automatically rewrite the obligation to point at the new artifact.

**Pros**: Linkage stays "current" without explicit invalidation.

**Cons**: Hides real drift. The brief distinguishes linkage (which can
be edited cheaply) from conformance (which must be re-verified). If
the system silently edits the linkage, the conformance claim that
"this code satisfies this obligation" cannot be retracted; the system
would be papering over failure rather than detecting it.

**Reason for rejection**: Conflates linkage and conformance — exactly
the distinction the brief draws.

### Alternative E: Skip the coverage-synthesis surface; expose verifiers as ad-hoc tools

**Description**: Implement the nine layer contracts but let operators
discover and invoke them as they would a CLI tool. No obligation
graph, no coordinator, no report.

**Pros**: Smallest possible surface area; verifiers are independently
useful.

**Cons**: Reintroduces tool-indexed reporting by another route
("operator ran X"). The framing is obligation-indexed; tool-shaped
deliverables would still produce obligation-shaped questions from
stakeholders ("which obligation does this satisfy?") that the system
cannot answer.

**Reason for rejection**: Misses the framing the brief specifies.

## Trade-offs and Consequences

### Positive consequences

- **Closes a real gap.** Correspondence between business intent and
  shipped behavior is preserved across the lifecycle, recoverable
  after merge, and reportable to non-engineer stakeholders.
- **Reuses every existing substrate.** Agent runs, prompts, knowledge
  pipeline, Feature Intent, audit, Inbox, TDD mode, project
  readiness, conformance guard — all are reused; none are replaced.
- **Layer model is extensible.** New verification kinds are new
  Ruby classes against a single interface, not new pipelines.
- **Selective cost.** The rubric selects layers per obligation; a
  small change to a low-risk obligation does not run the most
  expensive verifiers.
- **Targeted invalidation.** Content-addressed evidence means
  re-verification follows the change, not the obligation graph size.

### Negative consequences

- **Coordinator is the new surface to operate.** Operators must learn
  the obligation graph, the rubric, the four-class finding taxonomy,
  and the audit-entry surface. The brief names onboarding cost as an
  adoption principle; this is the cost the principle acknowledges.
- **The rubric's correctness depends on operator inputs.** If
  operators mark obligations incorrectly, the rubric selects poorly.
  Phase 2 ships configuration profiles that pre-fill the rubric's
  inputs from existing posture so a misconfigured project inherits
  safe defaults.
- **Evidence invalidation can be conservative.** When an
  obligation's intent changes, evidence keyed on the old claim is
  stale even if the implementation still satisfies the *new* claim.
  Recompute bounded by the obligation's evidence count, not the
  obligation graph size; the brief permits this conservatism.
- **Three entry paths complicate testing.** Each entry path has a
  different verifier plan; Phase 3 evaluation covers all three on
  representative obligations.

### Risks and mitigations

- **Risk**: Layer implementation drifts from contract. **Mitigation**:
  Phase 1 publishes the contract with formal property tests; layers
  cannot register without satisfying them.
- **Risk**: Rubric returns the same set for materially different
  obligations. **Mitigation**: Phase 2 adds a structural test that
  enumerates paired obligations and asserts distinct layer sets when
  the six category inputs differ.
- **Risk**: Bootstrap over-promises obligations. **Mitigation**:
  bootstrap is prompting + human accept/reject, not autonomous
  creation. The user owns the resulting set.
- **Risk**: Re-verification loops on every commit. **Mitigation**:
  evidence is content-addressed; only the claims whose content
  address changed are re-verified, bounded by the implementation
  diff and the obligation's evidence count.
- **Risk**: Inbox becomes a flood of obligation findings.
  **Mitigation**: the four-class finding taxonomy is structurally
  distinct; the Inbox filters to obligations the user owns; the
  coverage report is the canonical read surface, not the Inbox.

## Rollout Guard

The RDR initially ships **docs-only**: this PR contains the RDR, the
README update, and nothing else. The `lid_planning` run that converts
the RDR into LID artifacts is the next concrete step; implementation
issues ship behind the rollout guard below.

- **Flag**: `layered_verification_coordinator`, added to
  `FeatureFlags::DEFINITIONS` (`app/services/feature_flags.rb`) by the
  Phase 1 implementation issue, with owner `verification-runtime`,
  intent, rollout plan, and cleanup criteria per the existing
  `Definition` shape.
- **Default state**: off. The coordinator schedules nothing while the
  flag is off; obligation records and the store are created disabled,
  the audit-entry UI is hidden, and bootstrap is not offered.
- **Enablement surface**: per-tenant opt-in via
  `tenant_settings.features`, consistent with existing peer flags.
- **Wiring issue**: the first implementation issue adds the flag key,
  registers the obligation record types, and wires the run-time read
  path. Until both the run-time path is wired and the contract is
  enforced, the coordinator must not schedule verifiers.
- **Rollback action**: disable the flag for the tenant. No data
  migration; obligation records already created are inert; verifiers
  do not run; existing CI/security/conformance guards continue
  unchanged.
- **Cleanup criteria**: remove the flag once the closeout audit
  verifies the coordinator schedules verifiers, the rubric selects
  materially different plans for materially different obligations,
  evidence invalidation is targeted, and pilot projects have completed
  audit entry without regressing existing merge controls.
- **Mandatory host policies are not gated by this flag.** CI, security
  scanners, code review, branch protection, and conformance-with-
  approved-design remain unconditional and continue to run for every
  project regardless of the flag's state. The flag gates the
  coordinator and its layers, not the host.

## Implementation Plan

> Status: Draft. The five phases below are derived from the brief's
> three entry paths, nine layers, and the implementation plan section's
> separation of "initial usable capability" from "optional integrations
> and later generalization." Issue bodies carry `@spec VERIFY-###`
> annotations against EARS specs the `lid_planning` run materializes.

### Phase 1: Host substrate, obligation store, and the layer contract

- Add `layered_verification_coordinator` to `FeatureFlags::DEFINITIONS`
  and wire the runtime gate.
- Add the `business_obligations` migration (UUID for external id,
  project FK, slug, ownership, lifecycle, content-addressed body hash,
  knowledge artifact mirroring with `artifact_type: "business_obligation"`).
- Add the `BusinessObligation` model; validation rules; lifecycle
  services `BusinessObligations::Record`, `Supersede`, `Archive`; Pundit
  policy; CRUD controller surface for operators.
- Implement `app/services/verification/layer_contract.rb` (formal
  interface) and the layer registration manifest. Publish
  `docs/intent/layered-verification/layered-verification-design.md` and
  `layered-verification-specs.md`.
- Ship the cheapest, deterministic layers: `linkage_freshness`,
  `behavioral_test` (read `Projects::Readiness` and the project's
  runnable test command), and `implementation_specification_conformance`
  (delegate to `IntentConformance::VerifyAtMerge` for features with a
  released Feature Intent).
- @spec VERIFY-001 (host capability), VERIFY-002 (obligation store),
  VERIFY-003 (layer contract), VERIFY-004 (mandatory host policies
  unaffected)

### Phase 2: Coordinator, selection rubric, evidence model

- Implement `app/services/verification/coordinator.rb` and the
  verifier plan generation. Read obligation store, project readiness,
  configuration profiles, and the rubric; emit a verifier plan and a
  per-obligation coverage record.
- Implement `app/services/verification/rubric.rb` with the six risk
  categories the brief supplies. Add structural tests that
  enumerate paired obligations and assert materially different layer
  sets for materially different category inputs.
- Implement the evidence model (content-addressed, claim-keyed), the
  evidence store, and the invalidation routine.
- Wire the coordinator to one programmatic entry — `audit` — that
  runs the coordinator end to end against an obligation set on
  demand. The UI surface is hidden behind the flag.
- @spec VERIFY-005 (coordinator), VERIFY-006 (rubric), VERIFY-007
  (evidence model), VERIFY-008 (targeted invalidation)

### Phase 3: Remaining layers and entry paths

- Implement the semantic layers: `business_process_formalization`,
  `verification_planning`, `engineering_translation`,
  `mutation_test` (compose with `Mutant`), `formal_verification`
  (project-aware shell around the project's chosen checker, default
  off if the project has none), `independent_semantic_audit` (a
  dedicated `agent_harness` review against the obligation graph;
  this is the one layer that is its own agent run, per the brief's
  permission to have semantic layers drive their own runs).
- Add the design and bootstrap entry paths. Design entry composes
  with `create_feature` and `Lid::InjectIntoPrompt`. Bootstrap is a
  chat-driven flow that proposes obligations, waits for human
  accept/edit/reject, and commits the resulting set via the docs-only
  PR path.
- Build the business-facing review package (markdown rendering + an
  Inbox lane).
- Implement the four-class finding synthesis (`missing_evidence`,
  `stale_evidence`, `drifted_obligation`, `failed_verification`) as
  distinct Inbox items with class-distinct actions.
- @spec VERIFY-009 (semantic layers), VERIFY-010 (design entry),
  VERIFY-011 (audit entry ship-ready), VERIFY-012 (bootstrap entry),
  VERIFY-013 (finding taxonomy)

### Phase 4: Evaluation and reconsideration

- Run the brief's ten acceptance demonstrations against the
  implementation; collect evidence and cost numbers.
- Resolve the brief's reconsideration conditions:
  - Confirm Paid-as-host is sufficient, or re-scope as standalone
    (Alternative A).
  - Confirm the rubric produces materially different plans for
    materially different obligations on the evaluation corpus.
  - Confirm incremental adoption around a coherent business slice
    works on a representative workload without re-doing orchestration.
  - Confirm model-implementation conformance is achieved without
    forcing model edits on mechanical implementation changes.
- File any outstanding gap issues; update RDR status.
- @spec VERIFY-014 (acceptance demonstrations)

### Closeout

- RDR closeout/validation issue following
  [`closeout-checklist.md`](closeout-checklist.md); depends on
  Phases 1–4; updates RDR status and the README index. Tracks the
  umbrella epic with `Part of RDR-075`.

## Validation

### Implementation acceptance criteria

1. The `FeatureFlags::DEFINITIONS` entry
   `layered_verification_coordinator` defaults to off and toggles
   coordinator scheduling only.
2. The `BusinessObligation` model persists; Pundit policy authorizes
   project members and account operators; knowledge artifact mirroring
   produces searchable `artifact_type: "business_obligation"` rows.
3. Each registered layer passes the `Verification::LayerContract`
   formal property tests at registration time.
4. The coordinator reads the rubric and emits a verifier plan whose
   layer set varies materially across obligations whose six risk
   categories differ. Structural test fails if the rubric returns an
   identical set for two such obligations.
5. The coordinator runs an audit entry that produces an
   obligation-by-obligation coverage report; the report is
   content-stable across runs whose evidence has not changed.
6. When an obligation's intent is updated (claim hash changes),
   evidence keyed on the old claim is invalidated; evidence keyed on
   unrelated claims remains valid; the cost of the recompute is
   bounded by the obligation's evidence count, not the obligation
   graph size.
7. When an implementation commit changes only one product surface,
   evidence on unchanged surfaces remains valid; the cost of the
   recompute is bounded by the diff, not the obligation graph size.
8. CI, security scanners, code review, branch protection, and
   conformance-with-approved-design run unchanged with the flag off,
   with the flag on, and with the flag on for one project and off
   for another on the same account. The flag affects only
   coordinator-scheduled verifiers.
9. The bootstrap entry proposes obligations through chat, waits for
   human accept/edit/reject, and commits the resulting set via the
   docs-only PR path; autonomous minting is rejected by a structural
   test.
10. The four-class finding synthesis distinguishes missing, stale,
    drifted, and failed evidence; a failed finding cannot be cleared
    by re-running the same layer with a different prompt; the Inbox
    filters and actions differ by class.

### Testing approach

- Unit: obligation record lifecycle; layer contract property tests;
  rubric structural tests; evidence invalidation cost bounds;
  finding-class classification tests; flag-gated behavior on
  coordinator calls.
- Integration (Docker-required): full audit entry on a project with
  a representative set of obligations; bootstrap entry produces a
  docs-only PR with a valid obligation set; merge guard unaffected.
- Evaluation: ten acceptance demonstrations against real obligations
  on a representative workload, covering each of the three entry
  paths and each of the nine layers at least once.

### Test scenarios

1. **Scenario**: A new obligation is added; an audit entry is invoked.
   **Expected**: The coordinator schedules only the layers whose
   applicability predicates match the obligation's risk profile;
   evidence is collected; the coverage report lists the obligation as
   MET, NOT MET, or UNKNOWN with contributing verifiers and freshness.
2. **Scenario**: Two obligations in different risk categories
   (correctness-heavy vs. provenance-heavy).
   **Expected**: The rubric returns different layer sets; the
   structural test passes; cost differs accordingly.
3. **Scenario**: An obligation's intent is updated.
   **Expected**: Only the claim whose content address changed is
   invalidated; unrelated claims retain their evidence.
4. **Scenario**: An implementation commit moves a single function
   used by one obligation.
   **Expected**: Evidence on unrelated obligations is preserved;
   evidence on the affected obligation is re-verified.
5. **Scenario**: A failed-verification finding is produced by
   `independent_semantic_audit` on the current commit.
   **Expected**: The Inbox item is distinct from the
   intent-conformance lane; re-running `independent_semantic_audit`
   with a different prompt does not clear the finding; the human
   action to clear is design amendment, not edit-and-retry.
6. **Scenario**: Bootstrap is invoked on a new project.
   **Expected**: Obligations are drafted by the agent, presented to
   the user; the user accepts three, edits one, rejects two; the
   resulting four-obligation set is committed via a docs-only PR
   with the obligation documents under `docs/obligations/` and the
   corresponding knowledge artifacts created.
7. **Scenario**: The flag is toggled off mid-cycle.
   **Expected**: Coordinator scheduling stops; existing evidence is
   preserved; the Inbox no longer surfaces new obligation findings;
   CI/security/conformance guards continue unchanged.
8. **Scenario**: A pilot project adopts audit entry; existing merge
   controls continue to work; new obligation coverage reports are
   generated on demand.

### Desired user outcome (not yet achieved — supplied by the brief)

A single coherent RDR committed to viamin/paid defines the add-on
without requiring a separate service. From the RDR, an issue tree
files in the viamin/paid repo to drive incremental implementation. The
initial usable capability (audit entry, the cheapest layers, the
obligation store) lands behind a default-off flag. Operators can adopt
the add-on on a representative workload around a coherent business
slice without re-doing orchestration. Coverage is reported by business
obligation, not by tool. Linkage and conformance are distinct
recurrences; one can be edited, the other requires re-verification.
The four finding classes are first-class Inbox items. Mandatory host
policies continue to run unchanged.

The acceptance criteria above are necessary but not sufficient evidence
the outcome has been realized. Achieving it is the closeout criterion.

### Reconsideration conditions (supplied by the brief)

The implementation must surface and resolve, during Phase 4:

- If the planner finds that Paid cannot serve as host without
  building a separate service, the add-on may need to be re-scoped as
  a standalone product (Alternative A).
- If the selection rubric cannot produce materially different
  recommendations for different obligation types in evaluation, the
  layered architecture's value proposition weakens (Phase 2 structural
  test makes this checkable; Phase 4 evaluation confirms it on real
  data).
- If incremental adoption around a coherent business slice cannot be
  demonstrated on a representative workload without re-doing
  orchestration from scratch, the orchestration design needs
  revision.
- If the only way to satisfy acceptance criterion 6 is by forcing
  model edits on mechanical implementation changes, the linkage-vs-
  conformance distinction has been lost. The evidence model is
  content-addressed specifically to keep these distinct.

## Notes

- The layer taxonomy names supplied by the brief are preserved
  verbatim here so the issue tree and the LLD can map them to
  EARS spec IDs without renaming.
- The six rubric categories supplied by the brief are preserved
  verbatim for the same reason; their exact key names are LLD work.
- This RDR is the planning contract for the planner output the brief
  asks for. The implementation tree filed with this PR is sliced
  along entry paths (design, audit, bootstrap), layers (the nine
  contracts), and capabilities (host substrate, rubric, evidence,
  review package, finding synthesis); each issue body references
  this RDR by number.
