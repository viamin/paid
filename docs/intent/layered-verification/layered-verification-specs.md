# EARS Specs: Layered Verification of Business Intent and Implementation

> Testable claims for the layered-verification add-on
> ([RDR-076](../../rdrs/RDR-076.md)). Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target
> (`grep -r LAYERED-VERIFY-001`).
>
> These IDs are **reserved ahead of their implementation issues**
> (#4432–#4438, optional #4439–#4440); nothing under this prefix has shipped.
> `*Tests:*`/`*Code:*` lines below name the surfaces those issues are expected
> to add, not code that exists today. RDR-076's `V1`–`V20` references are
> local review IDs inside that document, not EARS IDs — see
> `layered-verification-design.md`'s
> [Traceability](layered-verification-design.md#traceability-rdr-v1v20--ears--replacement-tasks)
> table for the `V` → `LAYERED-VERIFY-*` mapping. Pending specs below carry
> their replacement-task issue reference per `CLAUDE.md`.

## Authority and canonical intent

- [ ] **LAYERED-VERIFY-001** — When a layered-verification request resolves a
  project whose effective persisted `projects.lid_mode` (an owner override
  included) is `"full"` or `"scoped"`, an obligation's canonical home SHALL be
  its existing `docs/intent/` EARS spec ID (or LLD/HLD prose section when no
  spec exists yet), referenced by ID and design-tree path; Paid SHALL NOT
  persist a second copy of the obligation's required-behavior text.
  Request-time framework resolution SHALL read the persisted effective
  `lid_mode` and SHALL NOT re-detect LID mode from the checkout or write
  `projects.lid_mode`; only the owner's explicit re-detect SHALL replace the
  persisted mode.
  *Tests:* `spec/services/layered_verification/obligations/resolve_framework_spec.rb`
  *Code:* `LayeredVerification::Obligations::ResolveFramework` (#4432)

- [ ] **LAYERED-VERIFY-002** — When a layered-verification request resolves a
  project with no persisted `lid_mode` but a detected OKF bundle, an
  obligation's canonical home SHALL be the OKF concept file's `scope_path`
  and content digest, using the same OKF bundle detection
  `Knowledge::Collectors::OkfCollector` already performs; OKF bundle
  detection SHALL be evaluated only when the effective persisted `lid_mode`
  is `nil`.
  *Tests:* `spec/services/layered_verification/obligations/resolve_framework_spec.rb`
  *Code:* `LayeredVerification::Obligations::ResolveFramework` (#4432)

- [ ] **LAYERED-VERIFY-003** — When a layered-verification request resolves a
  project with neither a persisted `lid_mode` nor a detected OKF bundle, Paid
  SHALL offer both a lightweight OKF-compatible CIR record (written to the
  target repository through the project's normal PR path) and LID adoption
  as a supported option, before any obligation sourced from that project can
  be marked `approved`; adopting the lightweight record SHALL NOT require
  adopting LID.
  *Tests:* `spec/services/layered_verification/obligations/resolve_framework_spec.rb`
  *Code:* `LayeredVerification::Obligations::ResolveFramework` (#4432)

- [ ] **LAYERED-VERIFY-004** — A `LayeredVerificationObligation`'s
  `approval_state` SHALL only transition to `approved` when its underlying
  framework record transitions (a merged LID spec/LLD edit, a merged OKF file
  edit, or a `ChangeIntent#activate!` for an offered CIR); chat exploration,
  acknowledgment, or deferral in the Inbox SHALL NOT change `approval_state`.
  A repair request that depends on a clarification still in `proposed` SHALL
  be rejected with an explicit "clarification not yet approved" reason.
  *Tests:* `spec/models/layered_verification_obligation_spec.rb`
  *Code:* `LayeredVerificationObligation#record_approval!` (#4432)

- [ ] **LAYERED-VERIFY-005** — The design and bootstrap entry paths SHALL
  reuse the same `LayeredVerificationObligation` / `*CorrespondenceClaim` /
  `*CheckResult` / `*Finding` contracts as the audit entry path; a bootstrap
  path's reconstructed-behavior observations SHALL be recorded distinctly
  from authorized/approved requirements (never merged into the same field),
  until a human confirms or revises the inference.
  *Tests:* `spec/services/layered_verification/bootstrap/propose_obligations_spec.rb`
  *Code:* `LayeredVerification::Bootstrap::ProposeObligations` (#4437)

## Obligation, correspondence, and evidence identity

- [ ] **LAYERED-VERIFY-006** — A `LayeredVerificationObligation` SHALL carry
  stable identity (`project_id`, `framework`, `external_identity`), a scoped
  description, `approval_state`, `external_revision`, and
  `superseded_by_id`; a bounded audit's report SHALL state each in-scope
  obligation's `approval_state` explicitly, including when authority is
  absent (`unresolved`), rather than omitting unauthorized obligations from
  the report.
  *Tests:* `spec/models/layered_verification_obligation_spec.rb`
  *Code:* `app/models/layered_verification_obligation.rb` (#4432)

- [ ] **LAYERED-VERIFY-007** — A `LayeredVerificationCorrespondenceClaim`
  SHALL declare its `claim_type` (one of `business_to_model`,
  `model_to_code`, `business_to_spec`, `spec_to_code`, `business_to_test`),
  the two representation references it bridges, its declared abstraction
  boundaries, and its declared assumptions; a claim record alone SHALL NOT be
  treated as evidence that the declared mapping holds.
  *Tests:* `spec/models/layered_verification_correspondence_claim_spec.rb`
  *Code:* `app/models/layered_verification_correspondence_claim.rb` (#4432)

- [ ] **LAYERED-VERIFY-008** — A `LayeredVerificationCheckResult` SHALL record
  `producer`, `execution_state` (`completed` \| `failed_assertion` \|
  `execution_error` \| `incomplete` \| `not_run` \| `non_applicable` \|
  `stale`), `obligation_coverage` (`supported` \| `contradicted` \|
  `unresolved`) computed independently of `execution_state`, `input_revision`,
  an `evidence_ref`, separate `agent_reported` and `recorder_verified`
  sub-fields, `cost`, and a non-optional `limitations` field. Re-running a
  check SHALL create a new row; it SHALL NOT overwrite a prior result.
  *Tests:* `spec/models/layered_verification_check_result_spec.rb`
  *Code:* `app/models/layered_verification_check_result.rb` (#4432, #4433)

- [ ] **LAYERED-VERIFY-009** — An audit's linkage-freshness producer SHALL
  report, as a `LayeredVerificationCheckResult`, any source/spec/code material
  within declared scope that has no `LayeredVerificationCorrespondenceClaim`
  referencing it at all, combining mechanical structural diffing with a
  bounded semantic read-through (`agent_harness`) for material a structural
  diff cannot detect (a new clause inside an existing paragraph).
  *Tests:* `spec/services/layered_verification/linkage_freshness_spec.rb`
  *Code:* `LayeredVerification::LinkageFreshness` (#4432, #4435)

## Model-check command integration

- [ ] **LAYERED-VERIFY-021** — A verification plan SHALL state its selected
  checks, fit, exclusions/non-applicability, required inputs, assumptions,
  resource expectations, and residual gaps; it SHALL permit a justified
  single-layer plan, SHALL NOT impose a minimum layer count, and SHALL NOT be
  able to waive CI, security, branch protection, code review, or approved-intent
  conformance — those host checks run independent of any plan outcome.
  *Tests:* `spec/services/layered_verification/plans/build_spec.rb`
  *Code:* `LayeredVerification::Plans::Build` (#4433)

- [ ] **LAYERED-VERIFY-022** — When a project declares a TLA+ model, an audit
  SHALL be able to run `tlc -config <Module>.cfg <Module>.tla` inside the
  existing isolated execution environment as a `formal_verification`
  producer, parsing `Model checking completed.` into `execution_state:
  completed`, a reported invariant violation into `execution_state:
  completed, obligation_coverage: contradicted` with its counterexample
  stored via `evidence_ref`, and a non-zero exit matching neither pattern into
  `execution_state: execution_error`. A missing `tlc` binary, a missing
  config pair, or no declared model SHALL be recorded as
  `execution_state: non_applicable` with a stated `limitations` reason, never
  silently skipped and never reported as a pass. A project without a
  declared model SHALL still be auditable through specs, scenarios, and tests
  without this producer.
  *Tests:* `spec/services/layered_verification/checks/tlc_runner_spec.rb`
  *Code:* `LayeredVerification::Checks::TlcRunner` (#4433)

## Audit-only permissions and separately authorized repair

- [ ] **LAYERED-VERIFY-010** — Requesting a `layered_verification_audit` run
  SHALL be authorized by `ProjectPolicy#manage_issues?`. A
  `layered_verification_audit` run SHALL NOT write to the target project's
  canonical intent, models, specs, tests, or production code; its only writes
  SHALL be `LayeredVerificationObligation`/`*CorrespondenceClaim`/
  `*CheckResult`/`*Finding` rows, `ArtifactStorage` evidence, and
  human-reviewed draft proposals. An audit run SHALL be able to complete with
  findings and SHALL NOT start a repair run on its own completion.
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`,
  `spec/policies/project_policy_spec.rb`
  *Code:* `app/temporal/workflows/agent_execution_workflow.rb`,
  `app/policies/project_policy.rb` (#4432, #4433)

- [ ] **LAYERED-VERIFY-011** — Requesting a `layered_verification_repair` run
  SHALL be authorized by `ProjectPolicy#update?`, independent of the bar used
  to request the audit that found it. A repair run SHALL be created only
  through an explicit, separately authorized request naming the affected
  artifacts, source support, behavioral effects, required decisions, and
  verifying checks; completing an audit or approving a clarification SHALL
  NOT, by itself, enqueue a repair run.
  *Tests:* `spec/policies/project_policy_spec.rb`,
  `spec/services/layered_verification/repairs/request_spec.rb`
  *Code:* `app/policies/project_policy.rb`,
  `LayeredVerification::Repairs::Request` (#4436)

- [ ] **LAYERED-VERIFY-012** — Every UI, project-scoped chat, and MCP entry
  point into layered verification SHALL read
  `FeatureFlags.enabled?(:layered_verification_add_on, project:)` and SHALL
  refuse the request when disabled; rollback SHALL preserve recorded evidence
  and findings and SHALL leave in-flight runs explicitly incomplete when they
  cannot safely finish, without introducing a second coordinator flag.
  *Tests:* `spec/services/layered_verification/*_spec.rb` (flag-gating shared examples)
  *Code:* `config/initializers/feature_flags.rb` (#4432)

## Agent-run goals and tool parity

- [ ] **LAYERED-VERIFY-013** — `AgentRun::GOALS` SHALL include
  `layered_verification_audit` and `layered_verification_repair` as distinct
  values; a `layered_verification_repair` run SHALL carry a non-nil
  `originating_audit_run_id`, set only by the explicit repair-request path
  described in `LAYERED-VERIFY-011`, never by audit-completion code. A manual
  audit SHALL be creatable without a GitHub issue while still carrying a
  project, resolved obligation scope, and budget.
  *Tests:* `spec/models/agent_run_spec.rb`
  *Code:* `app/models/agent_run.rb` (#4432, #4433)

- [ ] **LAYERED-VERIFY-014** — The project action, project-scoped chat tool,
  and MCP tool for requesting an audit or a repair SHALL dispatch through
  `Tools::Registry` into one shared tool class per action
  (`Tools::RequestLayeredVerificationAudit`,
  `Tools::RequestLayeredVerificationRepair`); each tool class SHALL declare
  the same authorization check named in `LAYERED-VERIFY-010`/`-011` for its
  action, and `available_to?`/`available_for_chat?` SHALL gate advertisement
  identically across the UI, chat, and MCP surfaces.
  *Tests:* `spec/mcp/tools/request_layered_verification_audit_spec.rb`,
  `spec/mcp/tools/request_layered_verification_repair_spec.rb`
  *Code:* `app/mcp/tools/request_layered_verification_audit.rb`,
  `app/mcp/tools/request_layered_verification_repair.rb` (#4433, #4436)

## Inbox, stale-action validation, and deduplication

- [ ] **LAYERED-VERIFY-015** — `Inbox::Queue::KINDS` SHALL include
  `LAYERED_VERIFICATION_FINDING_KIND`, backed by `Inbox::LayeredVerificationFinding`,
  scoped by project-policy visibility and independent of
  `auto_pick_enabled`. Its detail pane SHALL show the obligation's scope and
  source reference, conflicting source/model/spec claims, observed
  implementation behavior, check outcomes with freshness, why a decision is
  needed, and the possible resolutions with consequences. A clean audit
  report (every in-scope obligation `supported`) SHALL NOT create an Inbox
  entry.
  *Tests:* `spec/services/inbox/layered_verification_finding_spec.rb`
  *Code:* `app/services/inbox/layered_verification_finding.rb` (#4433)

- [ ] **LAYERED-VERIFY-016** — Chat discussion, acknowledgment, and deferral
  of a `LayeredVerificationFinding` SHALL NOT resolve it or approve any
  clarification; a proposed clarification SHALL show its pending-persistence
  state in the Inbox until its owning framework record is approved per
  `LAYERED-VERIFY-004`, and dependent repair requests SHALL be blocked until
  then.
  *Tests:* `spec/services/inbox/layered_verification_finding_spec.rb`
  *Code:* `app/services/inbox/layered_verification_finding.rb` (#4433)

- [ ] **LAYERED-VERIFY-017** — `LayeredVerificationFinding` identity SHALL be
  `(project_id, obligation_external_identity, correspondence_claim_type,
  cause_signature)`; a repeated audit reproducing the same identity SHALL
  attach a new observation to the existing unresolved finding rather than
  creating a second Inbox entry. Two findings SHALL NOT be merged on textual
  similarity alone.
  *Tests:* `spec/models/layered_verification_finding_spec.rb`
  *Code:* `app/models/layered_verification_finding.rb` (#4433, #4434)

- [ ] **LAYERED-VERIFY-018** — Before honoring an Inbox action on a finding
  (approve a clarification, request a repair, request a rerun), the handling
  controller action SHALL revalidate, immediately before acting: the
  obligation's `external_revision` still matches the project's current
  repository state; the acting user still holds the action's required
  permission; and no other repair run already exists for the same
  `originating_audit_run_id`, finding, and still-current `external_revision`.
  A stale revision, a lapsed permission, or an existing duplicate run SHALL
  cause the action to be rejected with an explicit reason, never silently
  proceed.
  *Tests:* `spec/requests/inbox/layered_verification_findings_spec.rb`
  *Code:* `app/controllers/inbox_controller.rb` (#4433, #4434)

## Change impact, interruption, and cancellation

- [ ] **LAYERED-VERIFY-019** — A change to an obligation's source, its
  declared model, or a check's execution environment SHALL invalidate every
  `LayeredVerificationCheckResult` whose `input_revision` no longer matches;
  evidence with established non-overlapping scope SHALL be retained, and
  evidence whose overlap cannot be established with confidence SHALL be
  invalidated by conservative fallback, with the limitation disclosed in the
  next audit report.
  *Tests:* `spec/services/layered_verification/invalidation_spec.rb`
  *Code:* `LayeredVerification::Invalidation` (#4435)

- [ ] **LAYERED-VERIFY-020** — An interrupted (cancelled, infrastructure
  failure, or budget-exhausted) `layered_verification_audit` or
  `layered_verification_repair` run SHALL, on retry, revalidate the freshness
  of recorded `LayeredVerificationCheckResult` rows, the obligation's current
  `approval_state`, the requester's current authorization, and remaining
  budget before reusing any of them; cancellation SHALL preserve every
  recorded check result and finding and SHALL report the run's outcome as
  explicitly incomplete, never as a pass. A repair's code mutation SHALL NOT
  be replayed merely because the surrounding audit retried.
  *Tests:* `spec/services/layered_verification/resumption_spec.rb`
  *Code:* `LayeredVerification::Resumption` (#4435)

## Business-review package

- [ ] **LAYERED-VERIFY-023** — A `LayeredVerificationReviewPackage` SHALL bind,
  at creation, the obligation set's `external_revision`s, declared scope,
  verification-plan revision, contributing `LayeredVerificationCheckResult`
  references, recorded approvals, and Inbox decisions made while open, to one
  reproducible package identity. A later change to any bound input SHALL
  create a new package revision and SHALL retain the prior record unchanged.
  Approving a review package SHALL NOT, by itself, authorize a repair or a
  release.
  *Tests:* `spec/models/layered_verification_review_package_spec.rb`
  *Code:* `app/models/layered_verification_review_package.rb` (#4433)
