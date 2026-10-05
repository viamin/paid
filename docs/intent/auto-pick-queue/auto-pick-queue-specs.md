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
  `analyze_issue` provider-exhaustion cooldown, Auto-Pick candidate selection
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
  `manual_review`, `needs_input`, `completed`, and `in_progress`. Separate
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

## Epic umbrella audits

- [x] **AUTO-PICK-QUEUE-009** — When an open issue carries the `epic` label
  and has no unresolved authoritative child or dependency, Auto-Pick SHALL
  select it for a final acceptance audit under the built-in defaults. An
  explicit project, effective-owner, or tenant skip-label override containing
  `epic` SHALL still exclude it. Markdown checkboxes, titles, and incidental
  issue references SHALL NOT create readiness dependencies, and open
  incidental body references or tracker heuristics SHALL NOT block an
  otherwise-resolved umbrella. A dependency edge from a child to its own
  parent SHALL be treated as a contextual parent reference, not a
  prerequisite, so umbrella/child pairs cannot deadlock.
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
  assessment is performed by the completion workflow via `agent_harness`;
  queue admission only consumes its persisted outcome.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `Issue#mark_partial_completion!`,
  `Automation::Strategies::AutoPick::DefaultCandidateSource`.

## Tier-infeasibility gating

- [x] **AUTO-PICK-QUEUE-011** — When an issue's most recent model selection
  pins a tier that no runner the project's owner has enabled for agent runs
  can satisfy (per the shared `Runners::TierCapability` contract), Auto-Pick
  candidate selection SHALL exclude that issue so the scheduler stops
  creating runs doomed to fail with `NoTierCapableRunner` (#4093).
  Feasibility SHALL be re-derived from live runner configuration on every
  pass, so the exclusion clears itself once a capable runner is configured.
  Issues with no model selection, or whose latest selection pins a
  satisfiable tier, remain eligible.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `Runners::TierCapability`.
