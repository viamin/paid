# EARS Specs: Auto-Pick Queue

> Testable claims for Auto-Pick queue seeding and draining. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r AUTO-PICK-QUEUE-001`).

## Toggle Lifecycle

- [x] **AUTO-PICK-QUEUE-001** — When a project has Auto-Pick disabled, the
  system SHALL cancel that project's queued Auto-Pick agent runs, including
  automatic `enhance_issue` recheck runs, so they are removed from scheduler
  and dashboard upcoming-queue views, while leaving manual and non-queued runs
  unchanged.
  *Tests:* `spec/models/project_spec.rb`, `spec/services/issues/enqueue_eligible_spec.rb`.
  *Code:* `Project#cancel_queued_auto_pick_runs`, `Issues::EnqueueEligible#call`.

- [x] **AUTO-PICK-QUEUE-002** — When an issue has an active automatic
  `analyze_issue` provider-exhaustion or unexpected-application-error cooldown, Auto-Pick candidate selection
  SHALL exclude that issue until its persisted next-attempt time. If the
  owner's relevant issue-analysis runner configuration, runner-health state, or
  authentication material changes after the cooldown was recorded, candidate
  selection SHALL treat the cooldown as reset immediately.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/services/issues/issue_analysis_backoff_reset_context.rb`.

- [x] **AUTO-PICK-QUEUE-003** — When a blocking dependency closes, the system
  SHALL reset an open dependent issue from `paid_state=recommend_close` to
  `paid_state=new` only after all of that dependent's still-recorded blocking
  dependencies are resolved, remove the mirrored recommend-close label so
  GitHub labels and `paid_state` stay consistent, and rely on the existing
  paid-state transition recheck path to re-enqueue the issue for Auto-Pick.
  *Tests:* `spec/services/issues/upsert_from_github_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/issues/upsert_from_github.rb`, `app/models/issue.rb`.

- [x] **AUTO-PICK-QUEUE-004** — When an issue has `no_code_required_at` set
  (an agent explicitly declared the issue's work complete without a code
  change), Auto-Pick candidate selection SHALL permanently exclude that issue
  from the completed-issue recovery path, regardless of `paid_state`, so a
  no-code-required issue does not loop back into the queue on its own.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

- [x] **AUTO-PICK-QUEUE-005** — Lifecycle reporting and Auto-Pick candidate
  selection SHALL derive their eligibility rule from one shared definition.
  *Tests:* `spec/models/issue_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/models/issue.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

- [x] **AUTO-PICK-QUEUE-008** — When a non-PR issue is open on GitHub,
  Auto-Pick candidate selection and lifecycle reporting SHALL NOT exclude it
  solely because of its internal `paid_state`, including `recommend_close`,
  `manual_review`, `needs_input`, `completed`, `analyzed`, and `in_progress`. Separate
  explicit safeguards, including active work, dependencies, and configured
  GitHub labels, remain authoritative and visible in the eligibility dashboard.
  The project issue list SHALL display each open issue's actual internal
  `paid_state`, including `analyzed`, rather than a fallback state label.
  *Tests:* `spec/models/issue_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/requests/projects_spec.rb`, `spec/jobs/issues/reenqueue_eligible_job_spec.rb`.
  *Code:* `app/models/issue.rb`, `app/helpers/application_helper.rb`,
  `app/views/projects/_issue.html.erb`, `Issues::ReenqueueEligibleJob`.

- [x] **AUTO-PICK-QUEUE-006** — When Auto-Pick is disabled at the project
  level, a trusted issue-scoped activation label (`paid-automation` or
  `paid-in-full`) MAY still queue work for exactly that issue through the
  explicit label-evaluation path, while every unlabeled issue remains outside
  the queue.
  *Tests:* `spec/services/automation/issue_evaluator_spec.rb`,
  `spec/temporal/activities/detect_labels_activity_spec.rb`.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/services/automation/label_policy.rb`.

- [x] **AUTO-PICK-QUEUE-007** — When an open issue carries any of the
  project's needs-input labels, Auto-Pick candidate selection SHALL exclude it
  regardless of its `paid_state`, so a state/label drift cannot mint work while
  a human clarification is pending (#3992).
  *Test:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

- [x] **AUTO-PICK-QUEUE-013** — Auto-Pick category exclusion SHALL use only
  the effective configured skip labels and needs-input label controls. Titles,
  body headings, and incidental open or unknown issue references SHALL NOT
  create a readiness dependency; explicitly declared dependencies and
  authoritative child relationships remain blocking. This shared rule SHALL
  apply to candidate selection, eager queue seeding, dequeue eligibility
  rechecks, and displayed eligibility.
  *Tests:* `spec/services/issues/auto_pick_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

## Existing dependency cycles

- [x] **AUTO-PICK-QUEUE-014** — When an account-scoped effective blocking
  dependency graph contains a strongly connected group, Paid SHALL reconcile
  it after dependency changes and through a bounded periodic backstop. The
  graph SHALL include resolved cross-project references and apply the existing
  open-state and contextual parent-reference exclusions. A reconciliation
  failure SHALL be reported as unavailable rather than as zero cycles.
  *Tests:* `spec/services/issues/dependency_cycles_spec.rb`.
  *Code:* `Issues::DependencyCycles`, `DependencyCycleReconciliationJob`.

- [x] **AUTO-PICK-QUEUE-015** — When reconciliation finds an effective cycle,
  Paid SHALL present one stable Inbox occurrence for the strongly connected
  group with a concrete linked cycle path, downstream-held-work count, and
  declaration provenance for each path edge when synchronization identified
  its GitHub source. Paid SHALL provide fallback inspection guidance when
  provenance is unavailable. The
  dashboard SHALL surface this cycle independently of its bounded held-issue
  detail list. Paid SHALL keep work held and SHALL NOT choose a declaration to
  remove; the occurrence clears only after a later synchronization observes an
  acyclic persisted graph. Personal Inbox removal SHALL affect only that
  occurrence for that operator.
  *Tests:* `spec/services/inbox/queue_dependency_cycle_spec.rb`,
  `spec/services/issues/dependency_cycles_spec.rb`.
  *Code:* `Inbox::Queue`, `Dashboard::HeldWorkDetails`,
  `app/views/dashboard/_inbox_detail_dependency_cycle.html.erb`.

- [x] **AUTO-PICK-QUEUE-016** — When an authorized operator starts a cycle
  agent run for a visible dependency-cycle Inbox occurrence, Paid SHALL require
  run authority for every project represented by that occurrence, create one
  synthetic agent run with the occurrence and effective graph revision
  snapshotted, and expose its queued, running, completed, or failed state on the
  same Inbox detail and authorized API/MCP surface. Paid SHALL reject a duplicate
  active run for the occurrence and SHALL permit an explicit new run
  only after terminal failure or a changed graph revision.

- [x] **AUTO-PICK-QUEUE-017** — A cycle-analysis prompt SHALL contain every
  member and effective internal edge of the strongly connected group, including
  issue title, labels, parent context, source URL, and declaration provenance.
  It SHALL include issue bodies only when the issue creator is trusted by the
  owning project and comments only when admitted by
  `Prompts::BuildForIssue.fetch_trusted_comments`; untrusted or unavailable
  content and unavailable provenance SHALL be recorded as unavailable coverage.

- [x] **AUTO-PICK-QUEUE-018** — A completed cycle analysis SHALL publish a
  reviewable recommendation containing candidate declaration changes, evidence,
  tradeoffs, missing or conflicting intent, each candidate resulting graph, and
  whether that graph is acyclic. Each resulting graph SHALL equal the complete
  snapshotted edge set after applying exactly the candidate's declared removals
  and endpoint corrections. Paid SHALL reject unaccounted edge additions or
  removals and SHALL NOT infer that removal of a single edge breaks a multi-edge
  strongly connected group.

- [x] **AUTO-PICK-QUEUE-019** — Analysis without a qualifying obvious-correction
  candidate (AUTO-PICK-QUEUE-021), and any attempted repair that cannot be
  fully verified (AUTO-PICK-QUEUE-022, AUTO-PICK-QUEUE-023), SHALL remain
  exactly as read-only as the strict #4804 contract: it SHALL NOT modify GitHub
  declarations, issue bodies, comments, labels, or local dependency records. A
  result whose snapshotted revision differs from the currently synchronized
  effective graph SHALL be identified as stale until a later synchronization
  observes an acyclic graph.
  *Tests:* `spec/jobs/cycle_analysis_job_spec.rb`,
  `spec/services/cycle_analyses/apply_repair_spec.rb`.
  *Code:* `CycleAnalyses::ApplyRepair`, `CycleAnalysisJob`.

- [x] **AUTO-PICK-QUEUE-021** — A candidate qualifies as an obvious correction
  only when all of the following hold against the snapshotted recommendation:
  (a) it is the sole candidate in the recommendation meeting (b)–(e) — a
  second candidate that also meets them makes the result ambiguous, not
  obvious; (b) its `missing_or_conflicting_intent` is empty; (c) its `evidence`
  is non-empty; (d) every edge referenced by its `declaration_changes` either
  carries a known `declaration_source == "issue_body"` (the only surface the
  existing GitHub write boundary can edit) or carries no persisted local
  provenance at all — a known `declaration_source` of `"issue_comment"`
  disqualifies the edge, but a missing one does not, since absent *local*
  provenance alone is never a stop condition when the live GitHub source
  turns out to hold an unambiguous declaration (AUTO-PICK-QUEUE-022 performs
  that live lookup before any write) — and belongs to an issue whose trusted
  content was available (not listed in `unavailable_content_issue_ids`); and
  (e) its
  `resulting_graph` is independently acyclic (AUTO-PICK-QUEUE-018). A
  candidate's edge count and the model's self-reported confidence SHALL NOT
  substitute for (a)–(e); a single-edge removal that fails any one of them is
  not obvious.
  *Tests:* `spec/services/cycle_analyses/obvious_correction_spec.rb`.
  *Code:* `CycleAnalyses::ObviousCorrection`.

- [x] **AUTO-PICK-QUEUE-022** — Before writing any declaration edit for an
  obvious-correction candidate, Paid SHALL require run authority for every
  project represented by the occurrence and re-derive the cycle from a fresh
  read of the account's effective dependency graph. Paid SHALL abort without
  writing, leaving every declaration untouched, when: the occurrence is no
  longer present; its occurrence/graph-revision differs from the snapshot; an
  edge's re-fetched declaration source no longer satisfies
  AUTO-PICK-QUEUE-021(d); a `correct` change's replacement no longer
  originates from the same declaring issue as its edge; or re-applying the
  candidate's declared changes to the freshly fetched edges would not yield an
  acyclic graph. When the fresh read itself is unavailable, Paid SHALL abort
  without writing rather than guess. When an edge's persisted provenance is
  absent, Paid SHALL NOT abort on that absence alone: it SHALL fetch the
  declaring issue's live GitHub body and attempt to locate the target
  reference there under the same isolation rule AUTO-PICK-QUEUE-023 uses for
  known-provenance edges, proceeding only when that live source and target
  match uniquely. Because this write happens before the run's own
  cancellation is otherwise checked, Paid SHALL re-check whether the run was
  cancelled during analysis immediately beforehand and SHALL skip the repair
  attempt entirely (never reaching GitHub) when it was.
  *Tests:* `spec/services/cycle_analyses/apply_repair_spec.rb`,
  `spec/jobs/cycle_analysis_job_spec.rb`.
  *Code:* `CycleAnalyses::ApplyRepair`, `CycleAnalysisJob`.

- [x] **AUTO-PICK-QUEUE-023** — A verified repair SHALL apply exactly the
  candidate's declared removals/corrections to the specific GitHub issue
  bodies that carry them, through `GithubClient#update_issue`, leaving
  unrelated body content, comments, labels, and every other declaration
  untouched, and SHALL record what changed and why on an audit event. Paid
  SHALL locate each declaration by requiring its target reference to resolve
  to exactly one line containing no other reference. For an edge with known
  local provenance, a target reference entirely absent from the freshly
  fetched body SHALL be treated as already applied and skipped without
  rewriting (safe idempotent retry after a prior successful edit). For an
  edge with no persisted local provenance, that same absence SHALL instead
  abort the repair without writing, since there is no record confirming the
  declaration was ever live to have been already edited — a live miss is
  indistinguishable from a declaration that never existed as stated. Either
  way, when the reference remains but cannot be isolated to one clean line
  the repair SHALL abort without writing. After writing, Paid SHALL re-parse the
  affected issue(s) from the same fetched body and confirm, via
  `Issues::DependencyCycles`, that the persisted effective graph for that
  group is acyclic before marking the run's repair outcome successful. When
  that confirmation read raises a coverage-unavailable error, Paid SHALL
  record a pending/unknown outcome rather than success or failure; a
  subsequent attempt SHALL re-verify without repeating any edit already
  observed on GitHub. A GitHub write failure after some but not all planned
  edits SHALL be recorded with exactly which edits applied, and SHALL NOT be
  reported as success.
  *Tests:* `spec/services/cycle_analyses/declaration_edit_spec.rb`,
  `spec/services/cycle_analyses/apply_repair_spec.rb`.
  *Code:* `CycleAnalyses::ApplyRepair`, `CycleAnalyses::DeclarationEdit`.

- [x] **AUTO-PICK-QUEUE-024** — Because the dependency-cycle Inbox always
  re-derives its occurrences from a fresh `Issues::DependencyCycles` read, an
  occurrence whose repair is confirmed acyclic SHALL NOT appear on the next
  read; the completed run remains reachable through ordinary run history. For
  every other outcome (no qualifying candidate, ambiguous, stale,
  unauthorized, provenance-unavailable, a declaration that could not be
  isolated, a write failure, confirmation-pending, or still-cyclic), the
  occurrence SHALL remain held and the Inbox detail SHALL show the evidence,
  the proposed change (or the missing decision), the outcome/coverage status,
  and a **view run** link. **view run** SHALL NOT be presented as a
  follow-up action for a confirmed repair.
  *Tests:* `spec/views/dashboard/_inbox_detail_dependency_cycle_spec.rb`.
  *Code:* `app/views/dashboard/_inbox_detail_dependency_cycle.html.erb`.

- [x] **AUTO-PICK-QUEUE-025** — The authorized API/MCP surface for a cycle
  agent run SHALL expose the same repair outcome and diagnostics (the
  obvious-correction decision, any applied changes, and the confirmation
  status) that the web Inbox renders, honoring the same project/issue
  authorization boundary.
  *Tests:* `spec/serializers/api/v1/inbox_entry_serializer_spec.rb`,
  `spec/mcp/tools/get_agent_run_spec.rb`.
  *Code:* `Api::V1::InboxEntrySerializer#cycle_analysis_run_payload`,
  `Tools::GetAgentRun`.

- [x] **AUTO-PICK-QUEUE-020** — Each cycle path/edge node Paid presents SHALL
  carry its locally synced title and current labels, and, when a parent issue
  is linked and that parent's project is within the viewer's authorized
  project set, the linked umbrella issue's number and title; an absent or
  not-yet-authorized parent SHALL omit umbrella context rather than failing
  the detail. The web Inbox detail SHALL keep this context readable on narrow
  screens (wrapping labels, truncated titles) and SHALL make the full issue
  title available on hover and on keyboard focus. The Mobile API cycle payload
  SHALL expose the identical title, label, and umbrella context for every path
  and edge node so API and agent clients can inspect the same cycle the web
  Inbox renders, honoring the same authorized-project visibility boundary.
  *Tests:* `spec/services/issues/dependency_cycles_spec.rb`,
  `spec/services/inbox/queue_dependency_cycle_spec.rb`,
  `spec/serializers/api/v1/inbox_entry_serializer_spec.rb`,
  `spec/requests/api/v1/inbox_spec.rb`, `spec/requests/inbox_spec.rb`.
  *Code:* `Issues::DependencyCycles::Cycle#umbrella_for`,
  `Api::V1::InboxEntrySerializer#dependency_cycle_issue_payload`,
  `DashboardHelper#dependency_cycle_issue_link`,
  `app/views/dashboard/_inbox_detail_dependency_cycle.html.erb`,
  `docs/api/openapi.yaml` (`DependencyCycleIssue`, `DependencyCycleParent`).

## Epic umbrella audits

- [x] **AUTO-PICK-QUEUE-009** — When an open issue carries the `epic` label
  and has no unresolved authoritative child or dependency, Auto-Pick SHALL
  select it for a final acceptance audit under the built-in defaults. An
  explicit project, effective-owner, or tenant skip-label override containing
  `epic` SHALL still exclude it. Markdown checkboxes, titles, and incidental
  issue references SHALL NOT create readiness dependencies. A dependency edge
  from a child to its own parent SHALL be treated as a contextual parent
  reference, not a prerequisite, so umbrella/child pairs cannot deadlock.
  *Tests:* `spec/services/issues/auto_pick_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/models/issue_spec.rb`.
  *Code:* `app/models/concerns/auto_pick_skip_labels.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/models/issue_dependency.rb`, `app/models/issue.rb`.

- [x] **AUTO-PICK-QUEUE-010** — When an epic's final audit has a terminal
  no-code-required or merged-PR outcome and that audit created or linked
  focused child/dependency work, Auto-Pick SHALL keep the epic blocked while
  that work is unresolved and SHALL permit a subsequent audit after it
  resolves. Later metadata changes to child/dependency work linked before the
  terminal audit SHALL NOT permit another audit. This exception SHALL apply
  only to epic umbrellas; ordinary issues retain their terminal safeguards.
  The re-arm comparison uses the *resolution* timestamp of the prerequisite
  (`closed_at`, stamped on the open -> closed transition; falls back to
  `parent_issue_linked_at` for children or `issue_dependencies.created_at`
  for legacy data) rather than the link timestamp, so an audit run that
  files work mid-run still re-arms once that work resolves after the audit
  terminates. Cross-project external owner/repo#N prerequisites whose
  target issue is observable in another project of the same account SHALL
  participate in the resolution comparison (joined via
  `IssueDependency.external_resolved_for_account`, mirroring
  `Issue.ready_for_work`'s `blocked_by_external` rule); targets whose project
  is not synced into the account or whose issue is not yet synced contribute
  no resolution timestamp and SHALL NOT re-arm the epic.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/models/issue.rb`.

- [x] **AUTO-PICK-QUEUE-012** — When a completion assessment records that a
  merged implementation PR left an ordinary source issue incomplete, Paid SHALL
  persist the partial outcome, the source PR correlation, and its authoritative
  prerequisite evidence. It SHALL keep the issue blocked until a prerequisite
  resolves after that assessment, then allow exactly one normal auto-pick
  continuation. Authoritative prerequisites SHALL include local
  `IssueDependency` targets, `parent_issue_id` children, and external
  owner/repo#N dependencies whose target issue is observable in another
  project of the same account (joined via
  `IssueDependency.external_resolved_for_account`, the same join
  `Issue.ready_for_work` uses for cross-project blocking). The external
  target's `closed_at` SHALL be the resolution timestamp; targets whose
  project is not synced into the account, whose issue is not yet synced, or
  whose target remains in an open blocking paid_state SHALL contribute no
  resolution timestamp and SHALL NOT re-arm the source. Repeated polling,
  unrelated sync writes, and an unchanged prerequisite SHALL NOT re-arm it.
  This exception does not apply without the explicit partial outcome and
  therefore preserves merged-PR duplicate-work protection. Semantic
  assessment runs asynchronously in
  `Issues::AssessPartialCompletionJob` so the GitHub poll path persists
  only the generic parking state and is not consumed by a synchronous LLM
  round trip per blocked row; queue admission consumes only that job's
  persisted outcome. The re-arm timestamp SHALL be captured when the issue
  is parked and passed to the asynchronous assessment, so a prerequisite
  resolving while the assessment runs can re-arm the issue. A transient nil
  assessment (harness error, timeout,
  malformed JSON) SHALL leave any existing partial-completion evidence in
  place so a stranded issue cannot lose its re-arm data to noise; only an
  explicit `partial: false` verdict SHALL clear the columns. The partial
  re-arm's eager path mirrors `child_times`'s PR exclusion by skipping the
  `partial_completion_parents` branch when the closing child is a pull
  request, so a closing tracking PR alone does not re-arm the parent.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/temporal/activities/fetch_issues_activity_spec.rb`,
  `spec/jobs/issues/assess_partial_completion_job_spec.rb`,
  `spec/models/issue_spec.rb`.
  *Code:* `Issue#mark_partial_completion!`,
  `Issue#clear_partial_completion!`,
  `Issues::AssessPartialCompletionJob`,
  `Activities::FetchIssuesActivity#park_dependency_blocked_issues`,
  `Automation::Strategies::AutoPick::DefaultCandidateSource`.

## Tier-infeasibility gating

- [x] **AUTO-PICK-QUEUE-011** — When an issue's most recent model selection
  pins a tier that no runner the project's owner has enabled for agent runs
  can satisfy (per the shared `Runners::TierCapability` contract), Auto-Pick
  candidate selection SHALL exclude that issue so the scheduler stops
  creating runs doomed to fail with `NoTierCapableRunner` (#4093).
  Feasibility SHALL be re-derived from live runner configuration on every
  pass, so the exclusion clears itself once a capable runner is configured.
  Feasibility SHALL be resolved over the whole `LlmModel::TIERS` catalog, so
  the model-selection lookup MAY be skipped when every catalog tier is
  satisfiable; that shortcut SHALL stay correct only while every persisted
  `model_selections.tier` is a catalog tier. Feasibility depends only on the
  owner's runner configuration, so a pass MAY resolve it once per owner and
  reuse it across the projects it evaluates; the memoized value SHALL NOT
  outlive the pass.
  Issues with no model selection, or whose latest selection pins a
  satisfiable tier, remain eligible.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/services/runners/tier_feasibility_spec.rb`,
  `spec/models/model_selection_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `Runners::TierCapability`, `Runners::TierFeasibility`.
