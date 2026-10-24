---
parent: PAID
prefix: LAYERED-VERIFY
---

# Low-Level Design: Layered Verification of Business Intent and Implementation

> Companion to the high-level design (`docs/high-level-design.md`) and
> [RDR-076](../../rdrs/RDR-076.md). This segment is the LID conversion of the
> accepted RDR: canonical intent/approval contracts, evidence and finding
> identity, initial model-check command integration, agent-run goals, and
> Inbox/UI/MCP boundaries for the layered-verification add-on. It owns design
> only — no runtime behavior ships through this segment's issue (#4431);
> implementation is tracked through #4432–#4438 and optional #4439–#4440,
> whose EARS references and approved scopes this segment supplies.

## Purpose

Deterministic checks inside one representation — a passing TLA+ model, a
green test suite — do not establish that the representation agrees with
another about ownership, ordering, retries, or failure behavior, or that
either agrees with approved business intent. Paid needs a bounded, reusable
way to state what an obligation requires, which checks were run against it,
what those checks actually establish, where representations disagree, and
what remains uncertain — without inventing a parallel intent store, a new
hierarchy of risk layers, or an automatic path from audit finding to code
change.

This segment is an **add-on hosted by Paid**, reusing Paid's existing
execution, knowledge, authorization, and review infrastructure rather than
standing up new services. Its primary unit of work is a scoped business
obligation, not a PR or a tool invocation; a PR remains valid evidence and a
valid repair vehicle, never the add-on's defining unit.

## Canonical EARS prefix

This segment allocates **`LAYERED-VERIFY`** as the one canonical EARS prefix
for the layered-verification add-on. The three prefixes used in the
superseded design PRs (#4364, #4384, #4406) — `VERIFY-*`, `LAYERED-VERIFY-*`,
and `LAYER-VERIFY-*` — were planning-stage references in those PRs' branches,
never merged into `docs/intent/`. None of the three are allocated EARS IDs in
this repository today: a repository-wide search for any of them outside this
segment, RDR-076 itself, and the historical RDR-075 audit reports (which record
the superseded PRs' planning-stage references) returns no allocated hits.
`LAYERED-VERIFY` is the only one
of the three carried forward, chosen because it matches this repository's
existing `<domain>-VERIFY` naming convention for cross-representation
verification segments (`APPLE-VERIFY`, `REVIEW-VERIFY`) and matches this
segment's folder name (`layered-verification`). `VERIFY-*` and
`LAYER-VERIFY-*` are retired planning references, not deprecated allocated
IDs — there is nothing to migrate because nothing under those prefixes ever
shipped.

RDR-076's `V1`–`V20` acceptance-criteria IDs are **local review references
inside the RDR document**, not EARS IDs. They are never implemented,
annotated in code, or cited by `@spec`. The [Traceability](#traceability-rdr-v1v20--ears--replacement-tasks)
section below maps each `V` reference onto the `LAYERED-VERIFY-*` IDs that
carry it forward as a testable claim.

## Entry paths

RDR-076 defines three entry paths that share one set of contracts (obligation
identity, authority references, check contracts, coverage views):

| Entry path | Starting point | First release |
| --- | --- | --- |
| **Audit** documented behavior | Business sources, code, specs, tests, optional models | Yes — #4432/#4433 |
| **Design** new behavior | Business sources and proposed behavior | No — #4437 |
| **Bootstrap** existing behavior | Business sources and sparsely-documented code | No — #4437 |

A project may use different entry paths for different obligations. This
design specifies the shared contracts once; the audit path is detailed first
because it is the first-release milestone, with design/bootstrap reusing the
same records (`LAYERED-VERIFY-005`).

## Authority and canonical intent

### Existing-framework resolution

A project's `lid_mode` (`docs/intent/lid-detection/`) already tells Paid
whether a project is a LID project and in which mode. That value is the
**persisted effective mode**: `projects.lid_mode` as last written by
`Projects::DetectLidMode` or by an owner's manual override from project
settings (`projects.lid_mode_overridden`), an override background detection
preserves rather than replaces. This segment reads that persisted value; it
never re-detects it. Framework resolution at audit/design/bootstrap request
time composes it into a three-way **framework classification** per project:

1. **LID** — the persisted effective `lid_mode` is `"full"` or `"scoped"`.
   The obligation's canonical home is the project's own `docs/intent/` EARS
   spec (or HLD/LLD prose for a not-yet-spec'd behavior). Paid references the
   spec ID and the design-tree path; it never re-expresses the obligation's
   text locally.
2. **OKF** — the persisted effective `lid_mode` is `nil`, but an OKF bundle
   is present (the same detection `Knowledge::Collectors::OkfCollector`
   uses: an `.okf/`-shaped directory of frontmattered Markdown, or a
   project-configured `options[:okf_paths]`). The obligation's canonical
   home is the OKF concept file; Paid references its `scope_path` and
   content digest.
3. **None** — neither a persisted LID mode nor a detected OKF bundle. Paid
   **offers** two things, explicitly, before any obligation can be marked
   approved: a lightweight CIR-style OKF-compatible Markdown record (reusing
   the same frontmatter shape `Knowledge::Okf::Frontmatter` already parses,
   written to the target repository through the project's normal PR path —
   never invented and held only in Paid's database), and LID itself as an
   available, supported structured option. Adopting the lightweight record
   never requires adopting all of LID; adopting LID is the project owner's
   explicit choice, made through the normal LID bootstrap phase 1
   (`docs/lid/workflow.md`), not implied by using this add-on.

The classification is resolved at every audit/design/bootstrap request, but
from persisted state — the effective `projects.lid_mode` plus OKF bundle
presence — never from a fresh LID re-detection of the checkout. The LID leg
therefore honors an owner's manual Full/Scoped override even when the current
checkout lacks detectable LID artifacts: a request-time checkout read is not a
substitute for the configured mode. Only the OKF leg reads the checkout at
request time (Paid persists no OKF-mode column to read), and it is evaluated
only when the effective `lid_mode` is `nil`, so it can never displace a
persisted — or overridden — LID classification with the `None`/offered-CIR
path. This add-on never writes `projects.lid_mode`; the owner's explicit
re-detect, the same `Projects::DetectLidMode` project-settings action
`docs/intent/lid-detection/` defines, remains the only operation that
replaces the persisted mode.

### Obligation persistence: reference, not duplicate

`LayeredVerificationObligation` (Paid-side, one row per scoped obligation per
project) never stores a second copy of the obligation's required-behavior
text. It stores:

| Field | Meaning |
| --- | --- |
| `project_id` | Tenant/project scope. |
| `framework` | `lid` \| `okf` \| `paid_offered_cir` \| `unresolved`. |
| `external_identity` | The EARS ID (`AUTH-UI-003`), OKF `scope_path`, or offered-CIR file path that is the canonical source. |
| `external_revision` | The git SHA (or OKF content digest) the record was last synchronized against. |
| `scope_description` | The bounded slice of behavior this obligation claims, in the project's own language — never the full source text. |
| `approval_state` | `proposed` \| `approved` \| `unresolved`. Mirrors the external framework's own approval state; Paid does not grant approval the source repository hasn't recorded. |
| `approved_revision_reference` | For every framework — `lid`, `okf`, and `paid_offered_cir` alike — the merged commit/PR in the target repository that carried the approval. For `paid_offered_cir` this is the merge that landed the offered CIR Markdown file, not the `ChangeIntent` row's id: the offered record is canonical only as repository Markdown (`LAYERED-VERIFY-003`), so the `ChangeIntent` draft→active lifecycle (reused, not new) is Paid-side proposal and approval-decision provenance, never the approval reference itself. |
| `superseded_by_id` | Self-referential, same shape as `ChangeIntent#superseded_by_id`. |
| `synced_at` | When `external_revision` was last confirmed current. |

**Offered-CIR approval boundary.** The `ChangeIntent` row and the offered-CIR
repository file are two identities, and this contract does not pretend they
are atomic: `ChangeIntent#activate!` records the Paid-side approval decision
(who approved, when, in what scope) but does not by itself transition the
obligation's `approval_state`. A `paid_offered_cir` obligation transitions to
`approved` only at the re-sync that follows its offered-CIR PR merging — the
sync that confirms the canonical file exists in the target repository, sets
`external_revision` to the merge SHA, and sets `approved_revision_reference`
to that merged commit/PR in the same transition. Until that re-sync the
obligation remains `proposed` with its pending-persistence state visible in
the Inbox (`LAYERED-VERIFY-016`), even though its `ChangeIntent` row is
already `active`, and a repair request that depends on it is rejected — the
approval is not canonical until its repository persistence completes, per
RDR-076 §1 ("dependent repair cannot use that clarification as canonical
until its required approval and persistence complete").

**Concurrent revisions.** Two audits (or an audit and a manual edit to the
target repo) can observe different `external_revision`s for the same
obligation concurrently. This segment does not attempt last-writer-wins
merge: every check result and finding records the `external_revision` it was
produced against (`LAYERED-VERIFY-008`), and a request to act on a finding
revalidates `external_revision` against the current repository state
immediately before acting (`LAYERED-VERIFY-018`, mirroring
`IntentConformance::VerifyAtMerge`'s "re-check immediately before the gated
action, not at scan time" pattern). A drifted revision does not silently
invalidate history — it marks the obligation `synced_at`-stale and requires a
fresh sync before the stale evidence can support a new decision.

**Clarifications.** A clarification proposed during an audit is recorded as
a draft against the obligation's own framework — a `ChangeIntent` draft for
`paid_offered_cir`/no-framework projects, or a proposed spec edit for LID
projects, or a proposed OKF file edit for OKF projects — and only becomes
`approved` through that framework's own review path. Chat exploration,
acknowledgment, or deferral in the Inbox never flips `approval_state` itself;
only the underlying framework record's approval **persisted in the target
repository** does — the project's own merged spec/OKF/CIR PR, confirmed by
re-syncing `external_revision` against its merge SHA. For an offered CIR,
`ChangeIntent#activate!` records the Paid-side approval decision as
provenance, and the obligation flips to `approved` only at that post-merge
re-sync (see **Offered-CIR approval boundary** above). A repair request
that depends on a still-`proposed` clarification is rejected with an explicit
"clarification not yet approved" reason, not silently queued.

## Obligation, correspondence, and evidence identity

Three distinct record types, matching RDR-076 §6's three-dimension
separation:

- **`LayeredVerificationObligation`** (above) — identity, scope, authority.
- **`LayeredVerificationCorrespondenceClaim`** — one row per declared mapping
  between two representations of the same obligation (business ↔ model,
  model ↔ code, business ↔ spec, spec ↔ code). Carries `claim_type`
  (free-text-selected from a fixed enum: `business_to_model`,
  `model_to_code`, `business_to_spec`, `spec_to_code`, `business_to_test`),
  the two representation references it bridges, declared abstraction
  boundaries, and declared assumptions. A claim is a statement to be checked,
  not itself evidence that the mapping holds.
- **`LayeredVerificationCheckResult`** — one row per executed check against a
  claim or directly against an obligation. Carries:
  - `producer` — the layer capability that ran it (one of RDR-076 §3's nine:
    `business_formalization`, `verification_planning`,
    `engineering_translation`, `linkage_freshness`, `behavioral_testing`,
    `formal_verification`, `mutation_testing`,
    `implementation_conformance`, `semantic_audit`),
  - `execution_state` — `completed` \| `failed_assertion` \| `execution_error`
    \| `incomplete` \| `not_run` \| `non_applicable` \| `stale`,
  - `obligation_coverage` — `supported` \| `contradicted` \| `unresolved`,
    computed independently of `execution_state` (a `completed` negative
    control can still report `contradicted`),
  - `input_revision` — the `external_revision` (plus code commit SHA, model
    file digest, or test revision, whichever apply) the check actually ran
    against,
  - `evidence_ref` — an `ArtifactStorage` key for any binary evidence (logs,
    counterexample traces, screenshots) and a structured JSON summary inline,
  - `agent_reported` vs `recorder_verified` sub-fields, following
    `AgentRuns::VerificationResultRecorder`'s separation of an agent's claim
    about what it did from what Paid's recording code independently confirmed
    (file exists, command exit code, parsed output shape) — an agent claiming
    "the model check passed" is `agent_reported`; the recorder's own parse of
    the tool's exit code and output is `recorder_verified`,
  - `cost` — token/time bounds actually spent,
  - `limitations` — free text the producing check is required to state
    (RDR-076 §3's "limitations" field; never optional).

Replaying a check never overwrites a prior `LayeredVerificationCheckResult`
row — a new run creates a new row referencing the same claim, preserving the
full history RDR-076 §7 requires ("preserve the original discrepancy and
decision history").

### Newly unmapped material

An audit's linkage-freshness producer compares the obligation's declared
scope against the current source/spec/code within that scope and reports, as
a `LayeredVerificationCheckResult` with `producer: linkage_freshness`, any
material that has no `LayeredVerificationCorrespondenceClaim` referencing it
at all — not only material whose existing claim went stale. This is a
structural diff (new file, new spec ID, new source clause under the declared
scope — code, mechanically detectable) combined with a bounded semantic
read-through for material that structural diffing cannot see (a new clause
added inside an existing paragraph — judgment, routed through `agent_harness`
per ZFC).

## Initial model-check command integration

The first supported external tool is the TLA+ model checker (`tlc`), reached
through a **documented command**, not a dedicated adapter:

- the audit declares the module/config file pair (`<Module>.tla`,
  `<Module>.cfg`) from the target repository's own tree,
- the command `tlc -config <Module>.cfg <Module>.tla` runs inside the same
  isolated execution environment (container, scoped credentials) every other
  project command already runs in — no new execution surface,
  this is a `formal_verification`-producer `LayeredVerificationCheckResult`,
- stdout is parsed for `Model checking completed.` (success,
  `execution_state: completed`) or a reported invariant violation with its
  counterexample trace (`execution_state: completed`,
  `obligation_coverage: contradicted`, counterexample stored via
  `evidence_ref`); a non-zero exit with neither pattern is
  `execution_state: execution_error`,
- a missing `tlc` binary, a missing config pair, or a project that declares no
  model at all is `execution_state: non_applicable` with an explicit
  `limitations` note — never silently skipped and never reported as a pass.

Additional check commands (mutation-testing runners, property-test
frameworks) follow the same shape: a documented command, a parse contract
into the same `LayeredVerificationCheckResult` fields, and an explicit
`non_applicable` gap when the tool is absent. A missing adapter is never a
prerequisite for shipping the audit path (RDR-076 §8).

## Audit-only permissions and separately authorized repair

RDR-076's central boundary — "audit and repair are separate operations" — is
enforced at three independent layers so no single mistake collapses it:

1. **Authorization bar.** Requesting an **audit** is authorized by
   `ProjectPolicy#manage_issues?` — the same bar as creating or triaging
   issues, since an audit only investigates and reports. Requesting a
   **repair** is authorized by `ProjectPolicy#update?` — the owner/admin bar
   already used for approval-gated design decisions (`FeatureIntentPolicy#approve?`'s
   stricter sibling), since a repair can mutate canonical intent, specs,
   models, tests, or code. The two checks are declared on two different
   actions; there is no shared "can touch layered verification" permission
   that would let a broader grant imply repair authority.
2. **Run-goal separation.** Audit and repair are two distinct `AgentRun::GOALS`
   entries (`LAYERED-VERIFY-013`), not one goal with a mode flag — so the
   workflow-dispatch branch that would let an audit "fall through" into repair
   behavior does not exist to begin with.
3. **No implicit enqueue.** Completing an audit run, or approving an intent
   clarification, never calls the existing automatic follow-up/retry path to
   start a repair run. A repair run's `originating_audit_run_id` (and, when
   relevant, `originating_clarification_id`) must be set by an explicit,
   separately authorized request; the audit-completion code path never sets
   it. This mirrors the RDR's "a completed audit or approved clarification
   must not call the existing automatic follow-up path to start a repair."

A repair run's goal activity names the affected artifacts, cites source
support, states behavioral effects, lists required decisions, and the checks
that will verify the correction, before Paid creates the run — surfaced to
the requester as the same "show the resolved scope before dispatch" pattern
the manual-audit trigger already uses.

Once dispatched, the repair run carries RDR-076 §7's post-repair
obligations (`LAYERED-VERIFY-025`): it corrects the named artifacts through
the project's normal review path (a PR, never a direct push); it records
each ambiguous decision through its framework-approved clarification before
the downstream cascade touches the artifacts it disambiguates; it preserves
the originating finding, its observations, and the detecting check results
unchanged — a finding resolves only through fresh supporting evidence
against a current revision (`LAYERED-VERIFY-024`), never through the
repair's own artifact edits; and it reruns every verifying check its request
named, recording each outcome as a new `LayeredVerificationCheckResult`
(`LAYERED-VERIFY-008`), with a check it cannot rerun recorded explicitly
(`not_run`/`incomplete`/`non_applicable` plus a stated limitation) rather
than silently dropped.

## Agent-run goals

Two new `AgentRun::GOALS` entries:

- **`layered_verification_audit`** — investigation only. Never writes to
  canonical intent, models, specs, tests, or production code in the target
  repository; its only writes are `LayeredVerificationObligation` /
  `*CorrespondenceClaim` / `*CheckResult` / `*Finding` rows, `ArtifactStorage`
  evidence, and (for a design-tree, LID-style audit) draft-only proposed spec
  edits surfaced for human review, never merged by the audit run itself.
- **`layered_verification_repair`** — a normal PR-producing run (reuses the
  standard plan/test/PR review lanes `create_pr` already uses), scoped to the
  artifacts named by its linked finding(s), carrying `originating_audit_run_id`
  and, when a clarification was required, `originating_clarification_id`.

Neither goal introduces a new workflow service. Both branch inside the
existing `Workflows::AgentExecutionWorkflow` the way `lid_planning` and
`create_feature` already do: `layered_verification_audit` skips the
host-network-reaching model-check path when no model is declared
(`non_applicable`, not a skipped container), and completion requires at least
one synthesized coverage view per in-scope obligation
(`LAYERED-VERIFY-024`) rather than a created-PR URL.
`layered_verification_repair` completes exactly like `create_pr` — it is
one — with the one addition that it records its post-repair obligations
(`LAYERED-VERIFY-025`: preserved failure evidence, recorded decisions, and
the named verifying checks rerun with new `LayeredVerificationCheckResult`
rows) before reporting completion.

A **manual audit** can be created without a GitHub issue (RDR-076's "Manual
audit... create an audit run without requiring a GitHub issue"), the one
documented exception to the normal issue-driven run-creation path; the run
still carries a `project_id`, a resolved obligation scope, a budget, and full
provenance.

## Tool parity: UI, project-scoped chat, and MCP

One authorization boundary, two thin adapters — the existing
`Tools::Registry` shape (`Tools::RequestLayeredVerificationAudit`,
`Tools::RequestLayeredVerificationRepair`, both `Tools::BaseTool` subclasses):

- `write_operation? == true`, `confirmation_mode: :post_dispatch` for both —
  a human confirms the resolved scope before the run actually dispatches,
  matching the manual-audit trigger's "show the resolved scope before
  dispatch" requirement and `record_change_intent`'s confirmation pattern.
- `authorize` declares the same Pundit action named in
  [Audit-only permissions](#audit-only-permissions-and-separately-authorized-repair)
  above — `:manage_issues?`/`ProjectPolicy` for the audit tool,
  `:update?`/`ProjectPolicy` for the repair tool — so a chat-dispatched
  request and a UI-dispatched request hit the identical check.
- The project action ("Request verification audit" on the project page) and
  project-scoped chat/MCP both call `Tools::Registry.dispatch`
  / `Tools::Registry.dispatch_mcp` into the same tool class; neither surface
  gets its own copy of scope resolution or authorization.
- `available_to?`/`available_for_chat?` gate advertisement the same way
  `RecordChangeIntent` does: a project-scoped chat session and the external
  MCP server both only advertise the repair tool to a user who actually holds
  the repair bar, so an under-permissioned chat turn never sees a tool it
  cannot call.

## Inbox, stale-action validation, and finding deduplication

### Inbox entry kind

A new `Inbox::Queue::KINDS` entry, `LAYERED_VERIFICATION_FINDING_KIND`, backed
by a new `Inbox::LayeredVerificationFinding` service mirroring
`Inbox::IntentConformance`'s shape: a scope (project-policy visibility, not
`auto_pick_enabled`-gated — a finding is actionable whether or not the
project auto-picks issues) and a detail-pane payload assembler. The detail
pane shows: the obligation's scope and source reference, the conflicting
source passages or model/spec claims, the observed implementation behavior,
the check outcomes with their `execution_state`/`obligation_coverage` and
freshness, why a decision is needed, and the possible resolutions (approve a
clarification, request a repair, defer with a reason) with their
consequences stated plainly. Evidence, the originating audit run, and the
obligation's canonical-record revision are linked, never re-rendered inline.

Routine audit progress and a clean audit report (every obligation
`supported`, nothing `unresolved` or `contradicted`) never create an Inbox
entry — they appear only in the project's audit history, per RDR-076's "clean
audit reports do not create Inbox work."

### Finding identity and deduplication

`LayeredVerificationFinding` is keyed by
`(project_id, obligation_external_identity, correspondence_claim_type,
cause_signature)`. `cause_signature` is a short, stable, kebab-case
identifier of the underlying discrepancy's *cause* — produced by the same
semantic-audit/implementation-conformance check that detects the discrepancy
(an `agent_harness` judgment, ZFC), the same role `claim_key` plays in
`REVIEW-VERIFY-003`'s dedup. A repeated audit that reproduces the same
`(claim_type, cause_signature)` pair attaches a new observation (timestamp,
`LayeredVerificationCheckResult` reference) to the existing unresolved
`LayeredVerificationFinding` row rather than creating a second Inbox entry.
Textual similarity between two findings' descriptions is never, by itself,
grounds to merge them — only a matching `cause_signature` from the detecting
check does (per RDR-076 §2's explicit "distinct conflicts remain distinct;
textual similarity alone is not enough to merge them").

A deferred finding keeps its history and reason visible and stays reachable
from the Inbox's disabled/deferred scope; only a recorded authoritative
resolution with fresh supporting evidence, or an explicit, revision-bound
exception record (mirroring `IntentConformanceResolution#resolution_type:
implementation_exception`, scoped to the exact revision it was granted
against), closes it.

### Stale-action validation

Before honoring any Inbox action on a finding (approve a clarification,
request a repair, request a rerun), the controller action revalidates, in
this order, immediately before acting — never trusting a value cached when
the page rendered:

1. the finding's obligation `external_revision` still matches the project's
   current repository state (otherwise: reject, surface "the source has
   changed since this finding was recorded," offer a rerun);
2. the acting user still holds the action's required permission bar (an
   owner demoted since page-load cannot approve a repair that was staged
   while they were still an owner);
3. no other repair run already exists with the same
   `originating_audit_run_id` + finding + still-current `external_revision`
   (duplicate-run admission — a second click, or a second browser tab, cannot
   create a second linked run for the same unresolved finding at the same
   revision).

This mirrors `IntentConformance::VerifyAtMerge`'s "re-verify identity against
freshly fetched state immediately before the gated action," generalized from
"before merge" to "before any Inbox action with downstream authority."

## Change impact, interruption, and cancellation

**Dependency-aware invalidation.** A change to an obligation's source, its
declared model, or a check's execution environment invalidates every
`LayeredVerificationCheckResult` whose `input_revision` no longer matches.
Evidence demonstrably unaffected by the specific change (a check scoped to an
unrelated obligation, verified by path/scope non-overlap) is retained rather
than recomputed; when overlap cannot be established with confidence, the
conservative fallback invalidates and the limitation is disclosed in the next
audit's report, never silently assumed current.

**Interruption and resumption.** An audit or repair run that is interrupted
(cancelled, infrastructure failure, budget exhaustion) resumes, on retry, by
re-reading its recorded `LayeredVerificationCheckResult` rows and
revalidating their freshness, the obligation's current `approval_state`, the
requester's current authorization, and remaining budget before reusing any of
them — never replaying a repair's code mutation merely because the
surrounding audit retried. Cancellation preserves every recorded check result
and finding and reports the run's outcome as explicitly incomplete, never as
a pass; this reuses the same cancellation semantics every other Paid agent
run already has (queue, capacity, budgets, isolated execution, logs,
cancellation) — no new cancellation mechanism.

## Optional automation: PR-triggered and scheduled audits

RDR-076 §2 marks two audit triggers as optional later integrations:
PR-triggered focused audits
([#4439](https://github.com/viamin/paid/issues/4439)) and recurring scheduled
audits through RDR-075 maintenance scheduling
([#4440](https://github.com/viamin/paid/issues/4440)). Their contracts live in
this segment because both dispatch the same `layered_verification_audit`
operation this segment defines; the recurrence machinery a scheduled audit
uses is owned by the `maintenance-runs` segment
(`docs/intent/maintenance-runs/`, `MAINT-060`–`MAINT-064`) and is consumed,
not duplicated. Neither trigger is a prerequisite for core RDR-076 closeout
(#4438), and neither grants repair authority or creates a merge blocker:
automatic triggers dispatch audit runs only, so every boundary in
[Audit-only permissions](#audit-only-permissions-and-separately-authorized-repair)
— the two Pundit bars, the two run goals, and the no-implicit-enqueue rule —
applies to them unchanged.

No rollout switch changes here. Both triggers read the existing
`layered_verification_add_on` guard (`LAYERED-VERIFY-012`) at admission in
addition to their own explicit, per-project, default-off opt-in
configuration; no second coordinator or trigger flag is introduced. The
concrete storage for the opt-in configurations belongs to #4439/#4440
implementation, not this design.

### PR-triggered focused audits (#4439)

**Admission and opt-in.** A PR-triggered audit is admitted only when the
`layered_verification_add_on` flag is enabled for the project and the project
has explicitly opted in to PR-triggered audits — a per-project, default-off
setting within the add-on's project configuration, never a tenant-wide
default (RDR-076 §2: "Explicit project opt-in"). The admitted run is a
`layered_verification_audit` run carrying the pull request's
`source_pull_request_number`, so the existing partial unique active-PR-run
index (`idx_agent_runs_unique_active_pr`, one active run per
`(project_id, source_pull_request_number, goal)`) structurally prevents a
second active audit for the same pull request — the same mechanism the
PR-review lanes already rely on (`LAYERED-VERIFY-026`). A trigger arriving
while an equivalent audit is already active is recorded with its provenance
(arrival, evaluated head revision, blocking run) and does not queue duplicate
work; a later trigger event for the current head re-evaluates admission.
Trigger provenance, current scope, waiting reasons, and links between runs,
findings, decisions, and pull requests are inspectable, per RDR-076 §2.

**Scope, revision, budget, and deduplication.** A PR-triggered audit pins the
pull request's head revision at admission and resolves its obligation scope
to the obligations whose declared scope intersects the pull request's changed
files — a focused audit of the obligations affected by the PR revision, never
an automatic full audit of every project obligation (RDR-076 §2: "Do not add
full layered audits to every PR"). Duplicate-work admission follows RDR-076
§2's "overlapping requests must not launch duplicate work for the same audit
scope/revision": an audit request — PR-triggered or manual — whose resolved
obligation scope and pinned revision match an already-active audit is not
admitted, regardless of trigger source (`LAYERED-VERIFY-027`). A PR-triggered
audit whose obligation scope cannot be resolved from the changed files
surfaces an actionable request — correct the project's trigger configuration
or request a bounded manual audit — rather than silently broadening to a
full-project audit, the same anti-silent-broadening rule `MAINT-013` states
for maintenance runs. Evidence from
prior audits that the pull request's changes do not invalidate is reused per
`LAYERED-VERIFY-019` rather than recomputed. Each dispatched audit carries
the bounded budget configured with the project's PR-trigger opt-in — there is
no per-trigger budget negotiation — and budget exhaustion remains an
explicitly incomplete outcome (`LAYERED-VERIFY-020`), never a pass.

**Lifecycle.** A new pull-request head or the pull request's closure does not
silently cancel an in-flight audit: the run completes against its pinned
revision, and its evidence and findings stay revision-bound and
Inbox-actionable; an authorized user may cancel it through the run's existing
cancellation path, which preserves recorded check results and findings and
reports the outcome as explicitly incomplete (`LAYERED-VERIFY-029`). A
cancelled or superseded PR audit never reports success.

**Evidence and Inbox lifecycle.** Findings recorded by a PR-triggered audit
use the same `LayeredVerificationFinding` identity and deduplication as every
other audit (`LAYERED-VERIFY-017`): a PR audit reproducing an existing
unresolved finding attaches an observation — with the PR revision and trigger
provenance — to that finding rather than creating a second Inbox entry, and a
clean PR audit creates no Inbox entry (`LAYERED-VERIFY-015`). A pull
request's merge or closure does not resolve findings; resolution follows
`LAYERED-VERIFY-024`'s fresh-evidence rule, and the PR link remains visible
on the finding as trigger provenance.

**No merge gate.** A PR-triggered audit is advisory: it posts no required
status check, adds no blocking label, and gates no merge by default
(`LAYERED-VERIFY-028`). Mandatory host policies — CI, security, branch
protection, code review, approved-intent conformance — run unchanged and
independently (`LAYERED-VERIFY-021`). Whether PR-triggered findings may
additionally surface as advisory pull-request comments through the existing
review publication lifecycle (the layered-verification analog of RDR-075's
advisory PR audits, #4333) is a deferred decision below; the default surface
is the Inbox.

### Scheduled audits (#4440)

**Scheduler reuse.** A recurring bounded audit is configured only through the
maintenance scheduling contract RDR-075 defines (`MAINT-060`–`MAINT-064`):
opt-in and default disabled, the same sources/scope/budget shape as a manual
audit request, timezone and next-occurrence exposure, overlap prevention
against an equivalent in-flight run, bounded missed-occurrence catchup, and
disable-stops-future-dispatch semantics. The scheduler owns recurrence; this
segment owns what it dispatches. Each occurrence dispatches the same
`layered_verification_audit` operation with the same contracts as a manual
audit — no maintenance-goal wrapper run, no second audit operation (RDR-076
§2: "It invokes the same audit operation"). Configuring a schedule requires
the audit-request authorization bar (`ProjectPolicy#manage_issues?`,
`LAYERED-VERIFY-010`); occurrence dispatch revalidates current state — the
add-on flag still enabled for the project, the schedule still enabled —
rather than a per-occurrence user decision, and a scheduled occurrence is
never dispatched while `layered_verification_add_on` is off for the project
(`LAYERED-VERIFY-030`). Whether the maintenance scheduler additionally
requires its own `maintenance_runs` guard for the non-maintenance objectives
it dispatches is owned by the `maintenance-runs` segment and resolved at
RDR-075 acceptance; this segment's contract requires only that no guard be
bypassed.

**Scope, revision, budget, and interruption.** Each occurrence pins the
then-current requested branch revision and carries the schedule's configured
budget; the scheduler's non-overlap rule and the same duplicate-work rule
(same obligation scope and pinned revision) prevent concurrent equivalent
audits (`LAYERED-VERIFY-031`). An occurrence whose configured sources or
scope cannot be resolved at dispatch surfaces an actionable Inbox request to
correct the schedule's configuration rather than silently broadening or
dropping the occurrence — the same anti-silent-broadening rule
`MAINT-013`/`MAINT-014` state for manual maintenance runs. Disabling a
schedule stops future dispatch without cancelling an already-active audit and
without deleting evidence; cancelling an active audit remains a separate
explicit action, and interruption, resumption, and budget-exhaustion
semantics are `LAYERED-VERIFY-020`'s, unchanged.

**Evidence and Inbox lifecycle.** Findings from scheduled audits follow the
same identity and deduplication (`LAYERED-VERIFY-017`) — a recurring audit
that reproduces an unresolved finding attaches an observation rather than
creating Inbox noise, exactly RDR-076 §2's "repeated audits attach new
observations to the same unresolved scoped finding" — and actionable findings
surface in the Inbox (`LAYERED-VERIFY-015`, `LAYERED-VERIFY-032`). A
scheduled dispatch never creates a repair run and never enqueues follow-up
work (`LAYERED-VERIFY-010`/`-011`; `MAINT-073`'s no-repair-as-scan-side-effect
rule holds for the audit objective too).

**Dependency boundary.** These contracts are finalized now, but
scheduled-audit runtime remains explicitly dependent on accepted RDR-075 and
its scheduling milestone ([#4332](https://github.com/viamin/paid/issues/4332)):
RDR-075 is still Status: Draft, its LLD/EARS are draft review artifacts, and
nothing here releases that dependency or authorizes implementation ahead of
it. The PR-triggered audit contracts above carry no such dependency — #4439
implements against the core audit capability (#4435/#4434) without waiting
for maintenance runtime. Neither task blocks core closeout (#4438).

## Access and tenant boundaries

Source reads, evidence, review packages, and tool invocations go through the
project's existing tenant/account authorization (row-level security) and
Pundit policies; nothing in this segment reads across a project boundary.
Untrusted target-repository code and commands execute only inside Paid's
existing isolated container, never on a host process. Evidence links and
reports apply the same secret redaction `SecretSafeMetadata` already applies
to `ExecutionAuditEvent` and `RunnerAuthAttempt` — a check result or finding
can never carry a raw secret-shaped value. The add-on is gated by the
default-off `layered_verification_add_on` feature flag described in RDR-076's
Rollout Guard, read through `FeatureFlags.enabled?(:layered_verification_add_on,
project:)` at every UI, chat, and MCP entry point named above — one guard, no
second coordinator flag.

## Business-review package

A `LayeredVerificationReviewPackage` binds, at creation: the obligation
set's `external_revision`s, the declared scope, the verification plan
revision, an index into the contributing `LayeredVerificationCheckResult`
rows, the approvals recorded against it, and the Inbox decisions made while
it was open — to one reproducible package identity (a content digest over
those bound references, following the same "digest identifies inputs, never
proves completeness" caveat RDR-076 §6 states explicitly). A later change to
any bound input creates a **new** package revision; the prior package record
is retained, never overwritten. Approving a review package records that the
business reviewer validated the workflows/rules/scenarios it covers at that
revision; it never, by itself, authorizes a repair or a release — those
remain the separately-performed operations defined above and under the
project's existing host policy.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Canonical EARS prefix | `LAYERED-VERIFY` | `VERIFY-*` (too generic — would collide project-wide); `LAYER-VERIFY-*` (singular, doesn't match the segment or folder name) | Matches the repo's existing `<domain>-VERIFY` convention (`APPLE-VERIFY`, `REVIEW-VERIFY`) and this segment's folder name. |
| Framework classification source | Effective persisted `projects.lid_mode` (an owner override included) plus request-time OKF bundle presence | Fresh checkout-time LID re-detection at each request | `lid_mode` is the persisted effective mode `lid-detection` owns, not a value derived afresh from the checkout; request-time re-detection would discard an owner's Full/Scoped override whenever the checkout lacks LID artifacts and misroute the project to the `None`/offered-CIR path. Only an explicit re-detect replaces the persisted mode. |
| Obligation canonical home | Reference the existing framework's own record (LID spec, OKF file, or offered CIR); Paid never duplicates the text | A Paid-native obligation document as the new source of truth | RDR-076 explicitly rejects a parallel obligation store; `ChangeIntent`/OKF already solve durable-intent persistence. |
| Offered-CIR approval reference | The merged repository commit/PR that landed the offered CIR file; `ChangeIntent#activate!` is Paid-side approval provenance only, and `approval_state` flips only at the post-merge re-sync | The `ChangeIntent` row's own id as `approved_revision_reference` | The offered CIR is canonical only as repository Markdown merged through the project's PR path (`LAYERED-VERIFY-003`); an internal row activated before that merge would mark the obligation approved while the canonical record and its revision do not exist yet, letting a dependent repair proceed against nothing — the exact canonical-source failure RDR-076 §1 rejects. |
| Audit vs. repair authorization bar | Two separate Pundit checks (`manage_issues?` for audit, `update?` for repair) on two separate tool/controller actions | One shared permission gating both | A shared gate would let a broad grant imply repair authority, collapsing the RDR's audit/repair separation at the one layer meant to enforce it. |
| Audit/repair run modeling | Two distinct `AgentRun::GOALS` values | One goal with a `mode: audit \| repair` metadata flag | A single goal needs an explicit runtime check to prevent repair behavior on every call site; two goals make "audit cannot repair" true by construction, matching the existing one-goal-per-lifecycle convention (`create_pr` vs `review`). |
| Finding identity | `(project, obligation external_identity, claim_type, cause_signature)`, with `cause_signature` an AI-judged stable key | Deduplicate by text/description similarity | RDR-076 explicitly rejects textual similarity as sufficient; `cause_signature` mirrors the already-shipped `claim_key` dedup key in `REVIEW-VERIFY-003`. |
| Evidence storage | Reuse `ArtifactStorage` for binary evidence; reuse the `VerificationResultRecorder` agent-claim/recorder-verified split for structured results | A dedicated layered-verification blob store or result table family with its own trust model | RDR-076 §Research Findings directs reuse of existing execution/evidence services; the claim/verified split is exactly the fail-closed shape this add-on needs for correspondence evidence. |
| Initial model-check integration | A documented `tlc` command run in the existing isolated execution environment, parsed into `LayeredVerificationCheckResult` | A dedicated TLA+ adapter/service | RDR-076 §3 states a documented command is an acceptable integration and a dedicated adapter is not a prerequisite; a missing tool must produce an explicit gap either way. |
| Tool surface | Two `Tools::BaseTool` subclasses (audit request, repair request), each declaring its own authorization | One combined tool with a mode parameter | RDR-076 treats "request an audit" and "request a repair" as distinct actions requiring distinct authorization; one tool would need an internal branch duplicating the two-Pundit-check design above. |
| Stale-action check timing | Re-validate revision/permission/duplicate-run immediately before acting, on every Inbox action | Validate once when the Inbox entry/page is rendered | Mirrors the already-shipped `IntentConformance::VerifyAtMerge` pattern; page-render-time validation goes stale the instant the repository or the user's role changes afterward. |
| PR-trigger opt-in surface | Per-project, default-off configuration read together with the `layered_verification_add_on` flag | A second per-trigger feature flag; tenant-wide default-on | RDR-076's enablement surface is existing tenant settings plus explicit project selection; a per-trigger flag would fork the one-guard rule `LAYERED-VERIFY-012` already fixes. |
| PR-trigger run dedup | `source_pull_request_number` + goal on the audit run, reusing the existing partial unique active-PR-run index, plus a scope/revision equivalence check across trigger sources | One audit per push; dedup by textual scope description | RDR-076 §2 forbids duplicate work for the same audit scope/revision; the index is the structural mechanism the PR-review lanes already rely on, and textual similarity is never identity (`LAYERED-VERIFY-017`). |
| PR-trigger merge posture | Advisory: findings surface through the Inbox; no required status check, blocking label, or merge gate by default | A default merge-blocking status; PR comments as the primary surface | RDR-076 §2 explicitly rejects a new default merge gate; the Inbox is the primary surface for human-actionable findings, and mandatory host policies already run independently. |
| Scheduled-audit trigger owner | Reuse the RDR-075 maintenance scheduling contract (`MAINT-060`–`MAINT-064`) dispatching the same `layered_verification_audit` operation | A layered-verification-owned scheduler; a maintenance-goal wrapper run | RDR-076 §2 marks the scheduled audit "owned by the maintenance scheduler"; a second scheduler or a wrapper goal would duplicate recurrence machinery and blur the audit operation's contracts. |
| Scheduled-audit contract timing | Finalize the layered-verification trigger contracts now; defer only the scheduler representation and guard composition to RDR-075 acceptance | Hold all contract drafting until RDR-075 acceptance | The trigger contracts' layered-verification side (admission, scope/revision identity, budgets, evidence/Inbox lifecycle) is decided by the accepted RDR-076; only the recurrence representation genuinely depends on RDR-075's final shape. |

## Open Questions & Future Decisions

### Resolved

1. ✅ Canonical prefix is `LAYERED-VERIFY`; `VERIFY-*`/`LAYER-VERIFY-*` are
   retired planning references with nothing to migrate (see
   [Canonical EARS prefix](#canonical-ears-prefix)).
2. ✅ Audit and repair are enforced as separate at the authorization, run-goal,
   and enqueue layers (see
   [Audit-only permissions](#audit-only-permissions-and-separately-authorized-repair)).

### Deferred

1. The exact migration path for a project that starts `framework: unresolved`
   and later adopts LID mid-way through an open audit — whether in-flight
   `paid_offered_cir` obligations auto-propose themselves as LID spec drafts,
   or require a fresh audit. Decide during #4437 (design/bootstrap phase).
2. Measurable evaluation thresholds and the representative workload RDR-076's
   Open LLD Decisions calls for, sufficient to justify broader defaults.
   Decide during #4434 (audit milestone evaluation), once real audit runs
   exist to measure.
3. Whether `LayeredVerificationCorrespondenceClaim` needs its own supersession
   chain (distinct from the obligation's) when a claim's abstraction boundary
   changes but the obligation itself does not. Decide during #4435 (change
   impact and evidence) against real multi-revision audit data.
4. Concrete table/column types, indexes, and migration plan belong to #4432
   — this design fixes field names and semantics, not storage DDL.
5. The concrete scheduler representation of a scheduled audit — whether a
   `MaintenanceSchedule` row carries a layered-verification audit objective
   key, or a sibling schedule record reuses the recurrence contract — and
   whether the scheduler's own `maintenance_runs` guard applies to the
   non-maintenance objectives it dispatches. Owned by the `maintenance-runs`
   segment; decided at RDR-075 acceptance / #4332, not here.
6. Whether PR-triggered audit findings may additionally surface as advisory
   pull-request comments through the existing review publication lifecycle
   (the layered-verification analog of RDR-075's advisory PR audits, #4333).
   Deferred until real PR-triggered audits exist to evaluate; the default
   surface is the Inbox.

## Traceability: RDR V1–V20 → EARS → replacement tasks

| RDR ref | EARS IDs | Replacement task(s) |
| --- | --- | --- |
| V1 | LAYERED-VERIFY-006, -007, -024 | #4432, #4433 |
| V2 | LAYERED-VERIFY-021, -022, -024 | #4433 |
| V3 | LAYERED-VERIFY-021, -022, -024 | #4433 |
| V4 | LAYERED-VERIFY-021, -024 | #4433 |
| V5 | LAYERED-VERIFY-001, -002, -003, -004 | #4432 |
| V6 | LAYERED-VERIFY-021 | #4433 |
| V7 | LAYERED-VERIFY-023 | #4433 |
| V8 | LAYERED-VERIFY-019 | #4435 |
| V9 | LAYERED-VERIFY-009 | #4432, #4435 |
| V10 | LAYERED-VERIFY-008 | #4432, #4433 |
| V11 | LAYERED-VERIFY-010 | #4432, #4433 |
| V12 | LAYERED-VERIFY-011, -025 | #4436 |
| V13 | LAYERED-VERIFY-022, -024 | #4433, #4436 |
| V14 | LAYERED-VERIFY-020 | #4435 |
| V15 | LAYERED-VERIFY-005 | #4437 |
| V16 | LAYERED-VERIFY-012 | #4432 |
| V17 | LAYERED-VERIFY-015 | #4433 |
| V18 | LAYERED-VERIFY-016 | #4433 |
| V19 | LAYERED-VERIFY-017, -018 | #4433, #4434 |
| V20 | LAYERED-VERIFY-013, -014 | #4432, #4433 |

The audit-first milestone (RDR-076's V1–V4, V6–V7, V17–V19, and the
audit-only portions of V10–V11 and V20) corresponds to EARS IDs
`LAYERED-VERIFY-001` through `-004`, `-006` through `-010`, `-012`, `-013`
through `-018`, `-021`, `-022`, `-023`, and `-024`, carried by #4432–#4434.
That enumeration is the strict EARS union of the RDR's milestone `V`
references (`-006` through `-008`, `-010`, `-013` through `-018`, `-021`
through `-024`) plus the Phase-1 foundation IDs every audit stands on:
`-001` through `-004` (framework/authority resolution), `-009` (linkage
freshness), and `-012` (the rollout guard — an explicit #4432 Phase 1
deliverable). `LAYERED-VERIFY-005` (design/bootstrap, #4437), `-011`
(repair authorization, #4436), `-025` (post-repair evidence preservation
and verifying-check reruns, #4436), and `-019`/`-020` (change impact and
resumption, #4435) remain post-milestone; where a listed ID's `*Code:*`
line also names a later issue (`-009` → #4435, `-014` → #4436), the
milestone verifies its audit-path scope as carried by #4432–#4433 and
evaluated at #4434. Full closeout requires all 25 IDs and #4435–#4438.
Optional automation is not required for core closeout and is not mapped to a
`V` reference because RDR-076 marks both as later, optional integrations; its
accepted slice is allocated as actual canonical EARS in this segment:

| Optional task | EARS IDs | Dependencies |
| --- | --- | --- |
| [#4439](https://github.com/viamin/paid/issues/4439) PR-triggered focused audits | LAYERED-VERIFY-026, -027, -028, -029 | #4435, #4434 |
| [#4440](https://github.com/viamin/paid/issues/4440) Scheduled audits via RDR-075 maintenance scheduling | LAYERED-VERIFY-030, -031, -032 | #4435, #4434, accepted RDR-075 + [#4332](https://github.com/viamin/paid/issues/4332) |

The PR-trigger contracts (#4439) do not await maintenance implementation;
the scheduled trigger's runtime (#4440) remains explicitly dependent on
accepted RDR-075 and its scheduling milestone
(see [Optional automation](#optional-automation-pr-triggered-and-scheduled-audits)).

Per this issue's acceptance criteria, #4432–#4438's own EARS references and
approved scopes are updated to cite these IDs **after** this planning segment
merges and is accepted — this document supplies the mapping; it does not
itself edit those issues. The same applies to #4439/#4440's
optional-automation slices (`LAYERED-VERIFY-026`–`-032`).

## References

- [RDR-076](../../rdrs/RDR-076.md) — the accepted design this segment converts.
- `docs/intent/lid-detection/` — the persisted effective `lid_mode` and its
  override/re-detect lifecycle, which this segment reads rather than
  duplicates.
- `docs/intent/change-intent-records/` — the `ChangeIntent` lifecycle reused
  for `paid_offered_cir` obligations and in-Inbox clarifications.
- `docs/intent/knowledge-base/` — OKF collection/export this segment reuses
  for OKF-framework obligations.
- `docs/intent/feature-approval/`, `docs/intent/approved-intent-conformance/`,
  `docs/intent/approved-intent-amendment/`, `docs/intent/approved-intent-merge-guard/`
  — the approval-provenance and stale-revalidation patterns this segment
  mirrors for obligation approval and stale-action checks.
- `docs/intent/review-verification/` — the Find→Verify→Synthesize,
  `agent_harness`-only, structured-JSON call convention this segment reuses
  for its correspondence-check producers.
- `docs/intent/operator-inbox/`, `docs/intent/inbox-foundation/` — the Inbox
  lane shape this segment's finding entry follows.
- `docs/intent/lid-aware-agent-runs/`, `docs/intent/focused-agent-runs/` —
  existing `AgentRun` goal/focus precedent for the two new goals.
- `docs/intent/artifact-storage/` — binary evidence storage reused unchanged.
- [RDR-075](../../rdrs/RDR-075-general-maintenance-runs.md) (General
  Maintenance Runs, Status: Draft) and `docs/intent/maintenance-runs/`
  (`MAINT-060`–`MAINT-064`) — own the recurrence machinery the optional
  scheduled audit (#4440) consumes; this segment owns the trigger contracts
  (`LAYERED-VERIFY-030`–`-032`) and does not implement scheduling.
