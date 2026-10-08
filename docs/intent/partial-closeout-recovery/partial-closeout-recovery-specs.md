# EARS Specs: Partial-Closeout Recovery

> Testable claims for making stalled partial closeouts visible and
> recoverable (#4120). Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target (`grep -r PARTIAL-CLOSEOUT-001`).

- [x] **PARTIAL-CLOSEOUT-001** — When `Issues::CloseoutEvidence` evaluates an
  issue, the system SHALL assemble the closeout evidence set from (a) merged
  PR rows linked to the issue via `parent_issue_id`, (b) merged PR rows matched
  to an originating `create_pr` run's recorded `pull_request_number` through
  the repo-qualified URL join, and (c) `no_code_required_at`, and SHALL derive
  a stable SHA-256 outcome-generation digest over that set using terminal
  timestamps (`agent_runs.completed_at`, falling back to the PR row's
  `created_at`), such that any newly linked merged PR or newly stamped
  no-code declaration produces a different digest.
  *Code:* `app/services/issues/closeout_evidence.rb`.
  *Test:* `spec/services/issues/closeout_evidence_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-002** — When an open, non-pull-request issue carries
  closeout evidence and is not admissible by
  `Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope`
  (so an epic that re-armed under `AUTO-PICK-QUEUE-010` is not stalled), and
  the issue holds no explicit operator state (`paused`, an auto-pick skip
  label, a needs-input label, `paid_state` in `needs_input`/`manual_review`,
  `runner_retry_abandoned_at`), has no blocking run and no open continuation
  request, and is not resolved-complete against the current evidence
  generation, the system SHALL expose it as a `partial_closeout` inbox entry
  (same auto-pick-gated project scope every lane uses, `INBOX-FOUNDATION-006`)
  whose detail shows the source PR/run links, the recorded completion outcome,
  unresolved prerequisites, and the exact reason automatic continuation cannot
  proceed. The entry SHALL clear when the issue closes, when a continuation
  request is opened for it, when it is resolved-complete against the current
  generation, and SHALL reappear only when a new evidence generation exists.
  *Code:* `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`,
  `app/services/issues/closeout_status.rb`,
  `app/views/dashboard/_inbox_detail_partial_closeout.html.erb`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/services/inbox/count_spec.rb`,
  `spec/services/issues/closeout_status_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-003** — When an authorized user requests a
  continuation for such an issue, the system SHALL persist an
  `IssueContinuationRequest` recording the actor, a required reason, the
  evidence snapshot, and the outcome-generation digest, and SHALL queue at
  most one `create_pr` run for the issue across double-clicks, replay, and
  concurrent requests: the request and its run are created in one transaction,
  a partial unique index allows only one open request per issue, and
  `idx_agent_runs_unique_active_issue` bounds the run itself. When the
  continuation run reaches a terminal status, the system SHALL close the
  request as consumed so the terminal guards re-arm — the issue is
  deliberately continued once per request.
  *Code:* `app/services/issues/request_continuation.rb`,
  `app/models/issue_continuation_request.rb`, `app/models/agent_run.rb`.
  *Test:* `spec/services/issues/request_continuation_spec.rb`,
  `spec/models/issue_continuation_request_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-004** — When a continuation is requested (or
  validated at admission), the system SHALL admit the issue by passing
  `continuation_authorized_issue_ids` to `eligible_scope`, which lifts only
  the merged-PR and no-code guards for exactly those issues; every other
  eligibility rule SHALL still apply — active-run uniqueness, dependencies
  (with unmet prerequisites explained to the user), trust, feature release /
  design revision holds, analysis backoff, tier feasibility, budgets, issue
  and project pauses, skip labels, needs-input, and manual review — and the
  request SHALL be refused with the specific reason when any of them blocks.
  The admission decision SHALL be preflighted with the same scoped
  `eligible_for_dequeue?` evaluation the dequeue recheck applies
  (`CloseoutStatus` residual guard, batched per project in
  `StalledCloseouts`), so a request can never queue a run that dequeue would
  cancel and supersede, and the lane explains the real blocker instead of the
  duplicate-work fallback. With no authorized ids, `eligible_scope` SHALL
  behave exactly as before.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/services/issues/request_continuation.rb`,
  `app/services/issues/closeout_status.rb`,
  `app/services/issues/stalled_closeouts.rb`.
  *Test:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/services/issues/request_continuation_spec.rb`,
  `spec/services/issues/closeout_status_spec.rb`,
  `spec/services/issues/stalled_closeouts_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-005** — When a queued continuation run is considered
  for dispatch, the system SHALL recheck its scoped authorization at dequeue
  and run start (`AgentRuns::RecheckIssueEligibility` continuation branch,
  which applies regardless of `auto_pick?`): the run SHALL be cancelled and
  its request superseded when the request is no longer open, the current
  evidence digest differs from the request's digest, the issue is no longer
  admissible under the scoped lift (including explicit issue/project pauses),
  or the run's budget/feature gates at start refuse it. The run SHALL proceed
  when the authorization still holds.
  *Code:* `app/services/agent_runs/recheck_issue_eligibility.rb`,
  `app/jobs/process_run_queue_job.rb`.
  *Test:* `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-006** — When an authorized user resolves a stalled
  issue as complete, the system SHALL require closeout evidence, SHALL record
  the actor, a required reason, and the evidence digest it resolves against
  (`closeout_resolved_at`, `closeout_resolution_digest`,
  `closeout_resolved_by_id`), SHALL set `paid_state` to `completed`, and SHALL
  NOT write to GitHub. The resolution SHALL suppress the inbox entry only
  while the digest matches the current evidence generation; repeated GitHub
  sync SHALL NOT recreate the suppressed item without new evidence, and new
  terminal evidence SHALL recreate it. Resolution and continuation creation
  SHALL serialize on the issue: resolving SHALL supersede an open continuation
  authorization and cancel its unclaimed queued run before recording the
  resolution, so no continuation can dispatch after the issue is declared
  complete.
  *Code:* `app/services/issues/resolve_closeout.rb`, `app/models/issue.rb`.
  *Test:* `spec/services/issues/resolve_closeout_spec.rb`,
  `spec/services/inbox/queue_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-007** — When an authorized agent acts through the
  MCP/API surface, the system SHALL offer `request_issue_continuation` and
  `resolve_issue_closeout` tools that authorize `:run_agent?` on the project,
  call the same services, and emit the same audit records as the Inbox
  actions; prerequisite creation/linking reuses the existing `create_issue`
  tool with dependency wording. No raw database edit or `paid_state` reset is
  required for any recovery path.
  *Code:* `app/mcp/tools/request_issue_continuation.rb`,
  `app/mcp/tools/resolve_issue_closeout.rb`, `app/mcp/tools/registry.rb`,
  `app/controllers/projects/agent_runs_controller.rb`.
  *Test:* `spec/mcp/tools/request_issue_continuation_spec.rb`,
  `spec/mcp/tools/resolve_issue_closeout_spec.rb`,
  `spec/requests/projects/issue_continuations_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-008** — When a continuation is requested for an issue
  without closeout evidence, or by an unauthorized user, or across tenants,
  the system SHALL refuse the request (evidence gate, policy authorization,
  tenant-scoped lookup) without creating a run; a completed issue SHALL remain
  protected by the merged-PR/no-code guards unless an explicit continuation
  authorization exists; and an explicit operator pause (issue `paused`,
  project pause, skip label) SHALL NOT be bypassed by a continuation request.
  *Code:* `app/services/issues/request_continuation.rb`,
  `app/controllers/projects/agent_runs_controller.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.
  *Test:* `spec/services/issues/request_continuation_spec.rb`,
  `spec/requests/projects/issue_continuations_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-009** — When the Inbox renders, the
  `partial_closeout` kind SHALL be accepted by the Inbox kind filter and
  `Inbox::Count`'s cached badge SHALL include the lane and invalidate on lane
  membership transitions (continuation request opened/closed,
  `closeout_resolved_at` changes, and the github-state transition of an
  in-lane issue), following the `saved_change_to_*` /
  `bump_inbox_cache_version` pattern the other lanes use.
  *Code:* `app/controllers/inbox_controller.rb`, `app/services/inbox/count.rb`,
  `app/models/issue.rb`, `app/models/issue_continuation_request.rb`,
  `app/views/inbox/index.html.erb`.
  *Test:* `spec/requests/inbox_spec.rb`, `spec/services/inbox/count_spec.rb`,
  `spec/models/issue_continuation_request_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-010** — When an authorized operator requests
  `partial_closeout` chat context, the system SHALL retrieve the current
  closeout outcome, merged PRs and originating runs, issue acceptance
  criteria, unresolved prerequisites, scheduling blocker, and recorded
  resolution or continuation state on demand. It SHALL expose unavailable
  evidence as absent data rather than infer completion, and opening chat
  SHALL not resolve, continue, or otherwise mutate the issue.
  *Code:* `app/services/inbox/chat_context.rb`.
  *Test:* `spec/services/inbox/chat_context_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-012** — When a queued continuation run (created by
  either the Inbox `request_continuation` action or the
  `request_issue_continuation` MCP tool — both call
  `Issues::RequestContinuation` and so are covered uniformly) builds its
  create_pr prompt, the system SHALL include a required, non-suppressible
  "Continuation Context" section carrying the operator's stated reason, the
  closeout evidence snapshot the request was authorized against (merged PRs,
  no-code-required timestamp), the evidence-generation digest, and guidance on
  treating the reason as the remaining-work plan, not re-verifying already
  -evidenced work, not treating closed child issues as sufficient epic
  evidence, and leaving the issue or epic open when the full scope named in
  the reason is not resolved — alongside, never instead of, the standard
  issue/policy/style sections. The section's provenance metadata SHALL record
  the request id, requesting actor id, and evidence digest. An ordinary
  (non-continuation) run's prompt SHALL be unaffected, and rebuilding the
  prompt (activity replay) SHALL NOT duplicate the section.
  *Code:* `app/services/prompt_assembly/sections/continuation_context.rb`,
  `app/services/prompt_assembly/build_issue_prompt.rb`.
  *Test:* `spec/services/prompt_assembly/build_issue_prompt_spec.rb`,
  `spec/services/issues/request_continuation_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-011** — When a partial-closeout detail pane renders
  at any supported viewport width, the system SHALL keep the continuation
  reason input and submit button within the available pane width, with a
  persistent label and multi-line reason input above the submit button even
  in a narrow desktop pane.
  *Code:* `app/views/dashboard/_inbox_detail_partial_closeout.html.erb`.
  *Test:* `spec/system/dashboard_inbox_spec.rb`,
  `spec/system/partial_closeout_layout_spec.rb`.
  *Verification:* Chromium layout checks at 320, 375, 640, 768, 1024, and
  1280px viewport widths in a 300px-wide continuation section, plus a
  rendered Inbox browser check at mobile and desktop widths.

- [x] **PARTIAL-CLOSEOUT-012** — When `PartialCloseouts::ReconcileLegacy`
  processes a `create_pr` `AgentRun` whose partial PR has been authoritatively
  linked to its source issue (via `parent_issue_id` or the run's recorded
  `pull_request_number` URL join) and whose `reconciliation` is empty or
  carries no terminal `status`, the system SHALL treat the run as a legacy
  partial closeout: replay through `Llm::AnalyzePartialCloseout` to obtain a
  fresh assessment, route the assessment through `PartialCloseouts::Reconcile`
  (which provides replay-safe owner creation, `IssueDependency` persistence,
  parent-body dependency rewrite, and aggregated prerequisite notifications),
  and SHALL persist the resulting `reconciliation` record so subsequent
  reconciliation passes find the run already reconciled and skip it. The
  legacy path SHALL NOT mass-reset `paid_state`, SHALL NOT infer completion
  from closed children, and SHALL NOT auto-close the parent umbrella or any
  open epic (#4187).
  *Code:* `app/services/partial_closeouts/reconcile_legacy.rb`,
  `app/services/partial_closeouts/reconcile.rb`,
  `app/services/llm/analyze_partial_closeout.rb`.
  *Test:* `spec/services/partial_closeouts/reconcile_legacy_spec.rb`,
  `spec/services/partial_closeouts/reconcile_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-013** — When `PartialCloseouts::ReconcileLegacy`
  processes a legacy partial closeout, the system SHALL ground the assessment
  in current shipped behavior and intent: a gap whose criterion is already
  satisfied by merged work, closed prerequisites, or other current evidence
  SHALL be omitted from the assessment; a gap without an open owner SHALL be
  filed as a focused follow-up issue through `PartialCloseouts::Reconcile`'s
  owner creation path; a gap that requires a human action SHALL surface as a
  blocking Inbox prerequisite notification under
  `PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE` with the exact
  next-step wording. Repeated invocations against the same run SHALL NOT
  create duplicate owners, dependencies, or notifications — the persisted
  assessment (`reconciliation.assessment`) is reused on replay, so gap
  indices stay stable across attempts, and a run with a terminal
  `reconciliation.status` SHALL be skipped (#4187).
  *Code:* `app/services/partial_closeouts/reconcile_legacy.rb`,
  `app/services/partial_closeouts/reconcile.rb`.
  *Test:* `spec/services/partial_closeouts/reconcile_legacy_spec.rb`,
  `spec/services/partial_closeouts/reconcile_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-014** — When `PartialCloseouts::ReconcileLegacy`
  processes a legacy partial closeout and a GitHub call fails after the
  `assessment` has been persisted but before reconciliation completes, the
  system SHALL preserve the recorded `reconciled_at`, `status`, and `error`
  fields on the run's `reconciliation` JSON, SHALL re-raise the
  `GithubClient::Error` so the caller can retry, and SHALL NOT create
  duplicate owner issues, dependencies, or operator notifications on the
  retry. A run whose reconciliation state shows `creating` for a gap
  SHALL resume owner recovery via the existing marker-based recovery path
  in `PartialCloseouts::Reconcile#create_owner!` rather than filing a second
  issue. Non-`GithubClient::Error` exceptions (e.g. an `ArgumentError`
  raised by `Reconcile#create_owner!` on a deterministic-bad assessment)
  SHALL be caught by `process_run`, recorded as `retryable_failure` with
  the `error` and `failed_at` fields populated, and the persisted
  `assessment` SHALL be discarded so the next pass regenerates instead
  of replaying the same deterministic input forever; the surrounding
  sweep SHALL continue scanning subsequent candidate runs rather than
  aborting at the wedging run (#4187).
  *Code:* `app/services/partial_closeouts/reconcile_legacy.rb`,
  `app/services/partial_closeouts/reconcile.rb`.
  *Test:* `spec/services/partial_closeouts/reconcile_legacy_spec.rb`.

- [x] **PARTIAL-CLOSEOUT-015** — When the legacy reconciliation sweep is
  invoked for an account, the system SHALL scope the run selection to that
  account (`TenantContext.with_system_access` to read across tenant RLS,
  with `project.account_id = <account>` to write only in scope), SHALL cap
  the candidate selection at the project's authoritative merged partial-PR
  links (`Issue` rows where `is_pull_request: true`, `pr_review_phase:
  "merged"`, and either `parent_issue_id` is set or an originating
  `AgentRun` matches by `pull_request_number`/`pull_request_url`), and SHALL
  skip a run whose latest `create_pr` attempt already persisted a terminal
  `reconciliation.status`. The sweep SHALL be restartable: an interrupted
  sweep can be re-invoked, and the second pass SHALL finish any run whose
  previous attempt left a recoverable `creating` state and SHALL skip runs
  whose reconciliation is already terminal (#4187).
  *Code:* `app/services/partial_closeouts/reconcile_legacy.rb`,
  `lib/tasks/issues.rake`.
  *Test:* `spec/services/partial_closeouts/reconcile_legacy_spec.rb`.
