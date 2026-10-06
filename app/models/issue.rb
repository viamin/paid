# frozen_string_literal: true

class Issue < ApplicationRecord
  belongs_to :reopened_by, class_name: "User", optional: true

  PAID_STATES = %w[new planning in_progress completed failed needs_input manual_review recommend_close analyzed].freeze
  REOPEN_REVIEW_REQUIRED_REASON =
    "Issue was reopened after closure. An operator must validate its current intent before it can be completed again."
  NON_BLOCKING_OPEN_DEPENDENCY_STATES = %w[recommend_close completed].freeze
  PR_REVIEW_PHASES = %w[draft restarted ready merged escalated].freeze
  # The first four reasons denote agent failure. `awaiting_approval` denotes
  # an unanswered human gate: the PR is green, blocked only on owner
  # approval, and has waited past the project ceiling. It must stay
  # distinguishable because `pr_escalation_reason` drives behavior elsewhere
  # (e.g. the token-limit override in #clear_escalation!).
  PR_ESCALATION_REASONS = %w[
    operational_failures
    failure_streak
    review_goal_retry_limit
    pr_auto_continue_token_limit
    awaiting_approval
  ].freeze
  PR_ESCALATION_REASON_OPERATIONAL_FAILURES = "operational_failures"
  PR_ESCALATION_REASON_FAILURE_STREAK = "failure_streak"
  PR_ESCALATION_REASON_REVIEW_GOAL_RETRY_LIMIT = "review_goal_retry_limit"
  PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT = "pr_auto_continue_token_limit"
  PR_ESCALATION_REASON_AWAITING_APPROVAL = "awaiting_approval"

  # Default per-issue per-provider retry cap: after a single provider fails this
  # many times for one issue, it is excluded from scheduling for that issue. Used
  # as the final fallback when no account-level or project-level override is set.
  # Keep in sync with the TenantSetting::DEFAULT_AGENT_SETTINGS default.
  DEFAULT_MAX_RUNNER_FAILURES = 10
  ISSUE_ANALYSIS_BACKOFF_BASE_DELAY = 5.minutes
  ISSUE_ANALYSIS_BACKOFF_MAX_DELAY = 1.hour
  ISSUE_ANALYSIS_BACKOFF_HISTORY_LIMIT = 12

  # Default label mirrored to GitHub to surface an issue/PR's paused state.
  # Adding the label in GitHub (or pausing from the UI) flips `paused`;
  # removing it flips `paused` back.
  PAUSED_LABEL = "paid-paused"

  # Canonical names for the escalation control labels (@spec GH-LABELS-006).
  # Defined once here and referenced by every activity/service that reads or
  # writes them, so the literal string exists in a single place. Applying
  # ESCALATED_LABEL pauses automation on a PR for human review; a trusted
  # user removing it is the dismissal signal (see MarkEscalatedActivity,
  # PullRequests::Unblock). DISMISS_ESCALATION_LABEL is an alternate marker
  # cleared alongside it in #clear_escalation!.
  ESCALATED_LABEL = "paid-escalated"
  DISMISS_ESCALATION_LABEL = "paid-dismiss-escalation"

  # Constants for synthetic alert issues. Shared with
  # Activities::ScanSecurityAlertsActivity which creates these issues.
  GITHUB_SOURCE = "github"
  UPSTREAM_PULL_REQUEST_SOURCE = "upstream_pull_request"
  SYNTHETIC_CODE_SCANNING_SOURCE = "code_scanning_alert"
  # Legacy source kept in VALID_SOURCES so existing Dependabot rows pass
  # validation on update (e.g. from agent-run completion activities).
  DEPENDABOT_ALERT_SOURCE = "dependabot_alert"
  VALID_SOURCES = [ GITHUB_SOURCE, UPSTREAM_PULL_REQUEST_SOURCE, SYNTHETIC_CODE_SCANNING_SOURCE, DEPENDABOT_ALERT_SOURCE ].freeze
  SEVERITY_ORDER = %w[critical high medium low].freeze
  SEVERITY_TO_PRIORITY = { "critical" => "P1", "high" => "P1", "medium" => "P2", "low" => "P3" }.freeze
  TRACKER_PATTERN = /\b(?:tracker|remaining\s+work|completion\s+criteria|phase\s+tracker|meta\s+issue)\b/i
  # Body match requires the tracker vocabulary to appear inside a markdown
  # heading (e.g. "## Tracker", "## Meta Issue"). Matching anywhere in
  # the body produced false positives for feature issues that incidentally
  # mention "tracker" in prose (e.g. "support custom issue trackers",
  # "deploy tracker"), which then got permanently excluded from auto-pick
  # by the "tracker with no body refs" safety net in Issues::AutoPick.
  # "remaining work" is intentionally excluded from the body-heading
  # pattern because it is a common section heading in regular
  # implementation issues (e.g. "## Remaining work\n- Add config"),
  # not a signal that the issue itself is a tracker/meta-issue. It is
  # still matched in the title pattern below, where the phrase is a
  # stronger tracker signal.
  TRACKER_BODY_HEADING_PATTERN = /^[#]{1,6}\s+.*\b(?:tracker|completion\s+criteria|phase\s+tracker|meta\s+issue)\b/i
  STRONG_TRACKER_BODY_HEADING_PATTERN = /^[#]{1,6}\s+.*\b(?:tracker|phase\s+tracker|meta\s+issue)\b/i
  # Large offset so synthetic github_issue_id values never collide with real
  # GitHub issue IDs (which currently range in the low billions).
  SYNTHETIC_CODE_SCANNING_ID_OFFSET = 800_000_000_000
  # Legacy offset for Dependabot synthetic issues. No new Dependabot issues are
  # created, but existing rows need this to generate correct github_url links.
  LEGACY_DEPENDABOT_ID_OFFSET = 900_000_000_000

  belongs_to :project
  belongs_to :parent_issue, class_name: "Issue", optional: true

  has_many :sub_issues, class_name: "Issue", foreign_key: :parent_issue_id,
                        inverse_of: :parent_issue, dependent: :nullify
  has_many :agent_runs, dependent: :nullify
  has_many :code_scanning_remediation_attempts, dependent: :destroy
  has_many :auto_merge_attempts, dependent: :destroy
  has_many :change_intents, dependent: :nullify
  has_many :issue_merge_subscriptions, dependent: :destroy
  has_many :intent_conformance_verdicts, dependent: :destroy
  has_many :intent_conformance_decisions, dependent: :destroy

  # @spec INTENT-AMENDMENT-003 — feature intent linkage; an
  # issue belongs to at most one feature tree (unique index on the join).
  has_one :feature_intent_issue, dependent: :destroy
  has_one :feature_intent, through: :feature_intent_issue

  has_many :issue_dependencies, dependent: :destroy
  has_many :dependencies, through: :issue_dependencies, source: :depends_on_issue
  has_many :reverse_issue_dependencies, class_name: "IssueDependency",
                                        foreign_key: :depends_on_issue_id,
                                        dependent: :destroy,
                                        inverse_of: :depends_on_issue
  has_many :dependents, through: :reverse_issue_dependencies, source: :issue
  has_many :continuation_requests, class_name: "IssueContinuationRequest", dependent: :destroy
  has_one :open_continuation_request, -> { open }, class_name: "IssueContinuationRequest"
  belongs_to :closeout_resolved_by, class_name: "User", optional: true

  validates :github_issue_id, presence: true, uniqueness: { scope: :project_id }
  validates :github_number, presence: true
  validates :title, presence: true, length: { maximum: 1000 }
  validates :github_state, presence: true
  validates :github_creator_login, presence: true
  validates :github_created_at, presence: true
  validates :github_updated_at, presence: true
  validates :paid_state, presence: true, inclusion: { in: PAID_STATES }
  before_validation { self.source ||= GITHUB_SOURCE }
  before_create :stamp_parent_issue_linked_at, if: :parent_issue_id?
  before_update :sync_parent_issue_linked_at, if: :will_save_change_to_parent_issue_id?
  before_save :sync_closed_at, if: :will_save_change_to_github_state?
  validates :source, presence: true, inclusion: { in: VALID_SOURCES }
  validates :pr_review_phase, inclusion: { in: PR_REVIEW_PHASES }, if: :is_pull_request?
  validates :pr_escalation_reason, inclusion: { in: PR_ESCALATION_REASONS }, allow_nil: true
  validates :enhance_issue_rounds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :parent_issue_belongs_to_same_project, if: -> { parent_issue.present? }

  after_commit :broadcast_current_section, on: [ :create, :destroy ]
  after_update_commit :broadcast_changed_sections
  after_update_commit :enqueue_newly_unblocked_dependents, if: :github_just_closed?
  # When the parent issue closes (operator action on GitHub, or a later
  # full closeout run via UpdateIssueWithPrActivity), the partial-closeout
  # prerequisite Inbox notification the operator never dismissed is stale:
  # the work it gated is no longer pending. Mirror the dependency-resolved
  # eager re-enqueue path so stale notifications do not keep the dismissal
  # state out of date when the parent is later reopened.
  after_update_commit :resolve_partial_closeout_prerequisite_notifications, if: :github_just_closed?
  after_update_commit :enqueue_self_if_became_auto_pick_eligible, if: :auto_pick_recheck_needed?
  after_update_commit :cancel_orphaned_queued_runs, if: :work_no_longer_needed?
  after_commit :update_project_last_github_activity_at, on: [ :create, :update ]

  # UI -> GitHub: whenever the local `paused` flag flips, mirror it onto the
  # issue/PR by adding or removing the `paid-paused` label. `before_save`
  # stamps the sync epoch (`paused_at`) so the GitHub -> App sync can reject
  # stale reflections of our own (possibly failed) push. Best-effort: a GitHub
  # failure is logged, and the next sync reconciles the label.
  before_save :stamp_paused_at, if: :will_save_change_to_paused?
  after_commit :sync_paused_label_to_github, if: :saved_change_to_paused?

  # Keeps `needs_input_since` synchronized with the `paid_state` transition so
  # the Inbox::Queue service can order oldest-waiting-first without scattered
  # updates at every write site. Stamps when the issue enters "needs_input",
  # clears when it leaves. Idempotent: re-applying the same state is a no-op.
  # @spec INBOX-FOUNDATION-001
  before_save :sync_needs_input_since, if: :will_save_change_to_paid_state?

  # Same contract as sync_needs_input_since, for the other hard-stop state:
  # `updated_at` is a shared touch timestamp bumped by label syncs and unrelated
  # writes, so it cannot report how long an issue has actually been parked in
  # manual_review (the same problem pr_escalation_started_at was added to solve
  # on the PR side). Stamps on entry, clears on exit; `manual_review_reason` is
  # set by the caller alongside `paid_state` (see IssueEnhancements::
  # StopForManualReview) so it is cleared here too rather than left stale.
  # @spec ISSUE-ENHANCEMENT-012
  before_save :sync_manual_review_started_at, if: :will_save_change_to_paid_state?

  # Invalidates the cached inbox nav badge count whenever an issue enters or
  # leaves the needs_input queue, enters or leaves manual_review, enters or
  # leaves the retry_limited queue (runner-retry-cap or push-permission
  # abandonment, cleared by a successful manual run), or when a waiting issue
  # is closed/reopened on GitHub, so the async badge endpoint recomputes
  # instead of serving a stale number for the rest of its TTL. Also covers a
  # pull request entering or leaving the escalated_pr inbox lane, since
  # merge_approval_candidate_state_changed? already watches
  # saved_change_to_pr_review_phase? for every pull request.
  # @spec OPERATOR-INBOX-010 @spec OPERATOR-INBOX-002C @spec OPERATOR-INBOX-002D @spec OPERATOR-INBOX-002E
  after_commit :bump_inbox_cache_version, if: :inbox_count_cache_invalidation_needed?

  scope :by_paid_state, ->(state) { where(paid_state: state) }
  scope :root_issues, -> { where(parent_issue_id: nil) }
  scope :sub_issues_only, -> { where.not(parent_issue_id: nil) }
  scope :issues_only, -> { where(is_pull_request: false) }
  scope :pull_requests_only, -> { where(is_pull_request: true) }
  scope :local_repository, -> { where(source: GITHUB_SOURCE) }
  # List surfaces (blocked PRs, retry-limited issues, recent activity) never
  # render the issue body; skipping it keeps the largest TEXT column off
  # list queries. Raises MissingAttributeError if a view starts using body —
  # then drop this scope from that query.
  scope :excluding_body, -> {
    select((column_names - %w[body]).map { |c| "#{table_name}.#{c}" })
  }
  # The operator's own per-PR hold, and the only thing that removes a PR from
  # the scan. The system never sets it: every recovery path is detected inside
  # the scan, so a system-set exclusion would hide the PR from its own recovery.
  # @spec QUEUE-TIER-006 @spec PR-ESCALATION-003
  scope :auto_continue_active, -> { where(auto_continue_paused: false) }
  scope :ready_for_work, ->(project) {
    # Match blocking_issues / lifecycle_statuses semantics: open dependencies
    # excluding agent-parked or agent-completed blockers, which are treated as
    # effectively resolved for downstream scheduling until GitHub is closed.
    blocked_by_local_open = IssueDependency
      .joins(:issue, :depends_on_issue)
      .where(
        depends_on_issue: { github_state: "open" },
        issues: { project_id: project.id }
      )
      .where.not(depends_on_issue: { paid_state: NON_BLOCKING_OPEN_DEPENDENCY_STATES })
      .excluding_parent_references
      .select(:issue_id)

    # Deployment-blocked deps: target PR has merged/closed, but has not
    # yet been marked as deployed. These keep the dependent issue blocked
    # so multi-step migrations (add column → backfill → drop) cannot be
    # started out of order.
    blocked_by_local_deployment_pending = IssueDependency
      .joins(:issue, :depends_on_issue)
      .where(
        requires_deployment: true,
        depends_on_issue: { is_pull_request: true, deployed_at: nil }
      )
      .where.not(depends_on_issue: { github_state: "open" })
      .where(issues: { project_id: project.id })
      .select(:issue_id)

    # External deps (owner/repo#number) block conservatively when we have
    # no visibility into the target's state. They unblock once a matching
    # Issue is observable in any project of the same account — typically
    # because both repos are synced into Paid. See
    # IssueDependency.still_blocking_external_for_account for the rule.
    blocked_by_external = IssueDependency
      .still_blocking_external_for_account(project.account_id)
      .joins(:issue)
      .where(issues: { project_id: project.id })
      .select(:issue_id)

    where(project: project, github_state: "open", is_pull_request: false, paused: false)
      .where.not(id: blocked_by_local_open)
      .where.not(id: blocked_by_local_deployment_pending)
      .where.not(id: blocked_by_external)
  }

  def github_url
    return github_html_url if source == UPSTREAM_PULL_REQUEST_SOURCE && github_html_url.present?
    return "https://github.com/#{project.upstream_full_name}/pull/#{github_number}" if source == UPSTREAM_PULL_REQUEST_SOURCE

    # Legacy Dependabot synthetic issues link to the Dependabot alert page.
    # No new Dependabot issues are created, but existing rows use synthetic
    # github_number values that don't correspond to real GitHub issues.
    if source == DEPENDABOT_ALERT_SOURCE &&
       github_issue_id.present? &&
       github_issue_id >= LEGACY_DEPENDABOT_ID_OFFSET
      alert_number = github_issue_id - LEGACY_DEPENDABOT_ID_OFFSET
      return "#{project.github_url}/security/dependabot/#{alert_number}"
    end

    # Synthetic CodeQL alert issues link to the code scanning alert page.
    if source == SYNTHETIC_CODE_SCANNING_SOURCE &&
       github_issue_id.present? &&
       github_issue_id >= SYNTHETIC_CODE_SCANNING_ID_OFFSET
      alert_number = github_issue_id - SYNTHETIC_CODE_SCANNING_ID_OFFSET
      return "#{project.github_url}/security/code-scanning/#{alert_number}"
    end

    return github_html_url if github_html_url.present?

    path = is_pull_request? ? "pull" : "issues"
    "https://github.com/#{project.issue_target_repository}/#{path}/#{github_number}"
  end

  def has_label?(label)
    labels.include?(label)
  end

  def trusted? # @spec UPSTREAM-ISSUE-002
    if project.upstream_pr_target?
      project.trusted_upstream_issue_author?(github_creator_login)
    else
      project.trusted_github_author?(github_creator_login)
    end
  end

  # @spec ISSUE-REOPEN-REVIEW-001
  def reopen_review_pending?
    paid_state == "manual_review" && manual_review_reason == REOPEN_REVIEW_REQUIRED_REASON
  end

  # @spec ISSUE-REOPEN-REVIEW-001
  def require_reopen_review!
    with_lock do
      reload
      update!(paid_state: "manual_review", manual_review_reason: REOPEN_REVIEW_REQUIRED_REASON)
    end
  end

  # @spec ISSUE-REOPEN-REVIEW-001
  def complete_unless_reopen_review_pending!(attributes = {})
    with_lock do
      reload
      return false if reopen_review_pending?

      update!({ paid_state: "completed" }.merge(attributes))
    end
  end

  # Records that a merged implementation is deliberately incomplete. The
  # assessment is produced by the completion workflow; this model method only
  # persists its deterministic outcome, parking-time baseline, and correlation
  # evidence.
  # @spec AUTO-PICK-QUEUE-012
  def mark_partial_completion!(pull_request_number:, reason:, parked_at: Time.current)
    update!(
      partial_completion_at: parked_at,
      partial_completion_pr_number: pull_request_number,
      partial_completion_reason: reason,
      paid_state: "manual_review",
      manual_review_reason: reason
    )
  end

  # Clears stale partial-completion evidence when a follow-up assessment
  # returns an explicit +partial: false+ outcome. A transient nil assessment
  # (handled by the caller) leaves the columns in place — partial columns
  # only ever clear on a durable verdict, never on a harness miss or
  # timeout, so a stranded issue cannot lose its re-arm evidence to
  # transport noise (AUTO-PICK-QUEUE-012).
  def clear_partial_completion!
    return unless partial_completion_at

    update!(
      partial_completion_at: nil,
      partial_completion_pr_number: nil,
      partial_completion_reason: nil
    )
  end

  def untrusted?
    !trusted?
  end

  def sub_issue?
    parent_issue_id.present? || parent_issue.present?
  end

  def tracker_issue?
    TRACKER_PATTERN.match?(title.to_s) || TRACKER_BODY_HEADING_PATTERN.match?(body.to_s)
  end

  def strong_tracker_body_heading?
    STRONG_TRACKER_BODY_HEADING_PATTERN.match?(body.to_s)
  end

  def body_referenced_issue_numbers
    body.to_s.scan(/(?<!\w)#(\d+)/).flatten.map(&:to_i).uniq
  end

  def closing_referenced_issue_numbers
    @closing_referenced_issue_numbers ||= parse_closing_references
  end

  def closed_issue(referenced_issues_by_number = {})
    closing_referenced_issue_numbers.each do |github_number|
      issue = referenced_issues_by_number[github_number]
      return issue if issue.present?
    end

    parent_issue
  end

  def has_associated_pull_requests?
    if sub_issues.loaded?
      sub_issues.any?(&:is_pull_request?)
    else
      sub_issues.pull_requests_only.exists?
    end
  end

  def review_rounds_count
    draft_review_count + pr_followup_count
  end

  # Returns the unified progress state for this PR. Pass +current_head_sha+
  # and +current_head_updated_at+ (the live PR head commit timestamp) to
  # enable the "new PR head commit" reset condition. Without those
  # parameters, only explicit reset markers and successful-run resets apply.
  def pr_progress_state(runs: nil, current_head_sha: nil, current_head_updated_at: nil)
    PullRequests::ProgressState.call(
      project:, issue: self,
      runs:, current_head_sha:, current_head_updated_at:
    )
  end

  def consecutive_unsuccessful_pr_runs(**kwargs)
    pr_progress_state(**kwargs).consecutive_unsuccessful_automatic_runs
  end

  def last_pr_meaningful_progress_at(**kwargs)
    pr_progress_state(**kwargs).last_meaningful_progress_at
  end

  def pr_escalation_worthy?(limit:, **kwargs)
    pr_progress_state(**kwargs).escalation_worthy?(limit:)
  end

  def pr_retryable?(limit:, **kwargs)
    pr_progress_state(**kwargs).retryable?(limit:)
  end

  def pr_stuck?(limit:, confirmations:, required_confirmations:, **kwargs)
    pr_progress_state(**kwargs).stuck?(limit:, confirmations:, required_confirmations:)
  end

  def associated_pull_request
    if sub_issues.loaded?
      open_prs = sub_issues.select { |si| si.is_pull_request? && si.github_state == "open" }
      return nil if open_prs.empty?

      open_prs.max_by do |pr|
        [ pr.github_updated_at || Time.at(0), pr.updated_at || Time.at(0) ]
      end
    else
      sub_issues.pull_requests_only
        .where(github_state: "open")
        .order(github_updated_at: :desc, updated_at: :desc)
        .first
    end
  end

  def needs_input?
    paid_state == "needs_input" && has_label?(project.enhance_issue_needs_input_label_name)
  end

  # Stamps `needs_input_since` on entry into `paid_state: "needs_input"` and
  # clears it on exit. A single model callback owns this transition logic so
  # every write path that touches `paid_state` converges on the same column
  # contract without scattered per-site updates.
  #
  # `paid_state_changed?` is the gate: re-applying the same state is a no-op,
  # and writes that don't touch `paid_state` never overwrite a valid timestamp.
  # The `||=` on entry preserves an existing timestamp when an agent re-applies
  # the needs_input label to an issue that is already awaiting input, so the
  # wait time keeps counting from the first transition rather than resetting.
  # @spec INBOX-FOUNDATION-001
  def sync_needs_input_since
    if paid_state == "needs_input"
      self.needs_input_since ||= Time.current
    elsif paid_state_was == "needs_input"
      self.needs_input_since = nil
    end
  end

  # Stamps `manual_review_started_at` on entry into `paid_state:
  # "manual_review"` and clears it (and the reason) on exit. Mirrors
  # sync_needs_input_since's contract exactly, including the `||=` that
  # preserves the original entry time across idempotent re-applications of the
  # same state.
  # @spec ISSUE-ENHANCEMENT-012
  def sync_manual_review_started_at
    if paid_state == "manual_review"
      self.manual_review_started_at ||= Time.current
    elsif paid_state_was == "manual_review"
      self.manual_review_started_at = nil
      self.manual_review_reason = nil
    end
  end

  def draft_phase?
    pr_review_phase.in?(%w[draft restarted])
  end

  def ready_phase?
    pr_review_phase == "ready"
  end

  def escalated_phase?
    pr_review_phase == "escalated"
  end

  def merged_phase?
    pr_review_phase == "merged"
  end

  # Releases the escalation hold and returns the PR to an automation-managed
  # phase. Owner-initiated clearings also restart the attempt counters: they
  # measure attempts since the owner last looked, and escalation is the moment
  # the owner looks. An escalation that clears itself (operational failures
  # recovering) passes +reset_counters: false+ — nobody looked, so the PR does
  # not earn a fresh failure budget.
  #
  # @spec PR-ESCALATION-005 @spec PR-ESCALATION-006 @spec PR-ESCALATION-007
  # @spec PR-ESCALATION-008 @spec PR-ESCALATION-025 @spec PR-ESCALATION-026
  def clear_escalation!(draft:, reset_counters: true)
    token_limit_override = pr_escalation_reason == PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT
    attrs = {
      labels: labels - [ ESCALATED_LABEL, DISMISS_ESCALATION_LABEL ],
      pr_review_phase: draft ? "restarted" : "ready",
      pr_escalation_reason: nil,
      awaiting_approval_since: nil,
      ci_retry_requested_at: nil
    }
    attrs.merge!(escalation_counter_reset_attributes) if reset_counters
    attrs[:pr_auto_continue_token_limit_overridden_at] = Time.current if token_limit_override

    update!(attrs)
  end

  def ready_to_work?
    blocking_issues.none? &&
      blocking_deployment_dependencies.none? &&
      blocking_external_dependencies.none?
  end

  def blocking_issues
    Issue.where(id: blocking_dependency_target_ids)
  end

  # Open dependencies that still block this issue, mirroring .ready_for_work:
  # excludes agent-parked/completed blockers and contextual parent
  # references (@spec AUTO-PICK-QUEUE-009).
  def blocking_dependency_target_ids
    issue_dependencies
      .joins(:issue, :depends_on_issue)
      .where(depends_on_issue: { github_state: "open" })
      .where.not(depends_on_issue: { paid_state: NON_BLOCKING_OPEN_DEPENDENCY_STATES })
      .excluding_parent_references
      .select(:depends_on_issue_id)
  end

  # Deployment-blocked dependencies whose target PR has merged/closed but
  # has not yet been marked as deployed. See .ready_for_work for the
  # corresponding query-level filter used during batch eligibility checks.
  def blocking_deployment_dependencies
    issue_dependencies
      .joins(:depends_on_issue)
      .where(requires_deployment: true)
      .where(depends_on_issue: { is_pull_request: true, deployed_at: nil })
      .where.not(depends_on_issue: { github_state: "open" })
  end

  def blocking_external_dependencies
    return IssueDependency.none unless project

    issue_dependencies.merge(
      IssueDependency.still_blocking_external_for_account(project.account_id)
    )
  end

  def dependent_issues
    dependents
  end

  # True when this issue represents a PR that has been marked as deployed
  # to production. Used by deployment-aware dependency resolution so a
  # step-N PR can unblock only after step-(N-1) has actually shipped.
  def deployed?
    is_pull_request? && deployed_at.present?
  end

  # Stamps this PR as deployed, clearing deployment-blocked dependents.
  # Callers (release-please integration, external webhooks, manual
  # attestation) must ensure the PR has actually reached production
  # before invoking.
  def mark_deployed!(time: Time.current)
    raise ArgumentError, "only pull requests can be marked as deployed" unless is_pull_request?

    update!(deployed_at: time)
  end

  # Compute lifecycle statuses for a collection of issues.
  # Returns a Hash of issue_id => :blocked | :in_progress | :eligible
  def self.lifecycle_statuses(issues) # @spec AUTO-PICK-QUEUE-005
    issues = issues.to_a
    return {} if issues.empty?

    issue_ids = issues.map(&:id)

    # Match blocking_issues semantics: open dependencies excluding non-blocking
    # parked/completed blockers and contextual parent references.
    blocked_by_local = IssueDependency
      .joins(:issue, :depends_on_issue)
      .where(issue_id: issue_ids, depends_on_issue: { github_state: "open" })
      .where.not(depends_on_issue: { paid_state: NON_BLOCKING_OPEN_DEPENDENCY_STATES })
      .excluding_parent_references
      .pluck(:issue_id)
      .to_set

    # Match blocking_deployment_dependencies semantics: target PR has
    # merged/closed but has not yet been marked deployed.
    blocked_by_deployment_pending = IssueDependency
      .joins(:depends_on_issue)
      .where(
        issue_id: issue_ids,
        requires_deployment: true,
        depends_on_issue: { is_pull_request: true, deployed_at: nil }
      )
      .where.not(depends_on_issue: { github_state: "open" })
      .pluck(:issue_id)
      .to_set

    # External deps that still block follow the same rule as ready_for_work:
    # the dep is satisfied when the target is closed or left open only for
    # human follow-up after an agent-complete/agent-parked outcome in a sibling
    # project of the same account. Grouped by account_id because the issues
    # collection may span tenants in principle (it currently does not in the
    # ProjectsController caller, but the method does not enforce that).
    blocked_by_external = issues
      .group_by { |i| i.project.account_id }
      .flat_map { |account_id, account_issues|
        ids = account_issues.map(&:id)
        IssueDependency
          .still_blocking_external_for_account(account_id)
          .where(issue_id: ids)
          .pluck(:issue_id)
      }
      .to_set

    # Match auto-pick's without_open_non_pr_subissues semantics: a parent is
    # blocked while it still has open non-PR sub-issues. Mirrors the
    # dependency rule above by exempting recommend_close/completed sub-issues.
    blocked_by_open_subissues = where(
      parent_issue_id: issue_ids,
      is_pull_request: false,
      github_state: "open"
    ).where.not(paid_state: NON_BLOCKING_OPEN_DEPENDENCY_STATES)
      .pluck(:parent_issue_id)
      .to_set

    blocked_ids = blocked_by_local | blocked_by_deployment_pending | blocked_by_external | blocked_by_open_subissues

    active_run_ids = AgentRun
      .where(issue_id: issue_ids, status: AgentRun::UNFINISHED_STATUSES)
      .pluck(:issue_id)
      .to_set

    has_open_pr_ids = open_pull_request_parent_issue_ids(issue_ids: issue_ids)
      .distinct
      .pluck(:parent_issue_id)
      .to_set
    paid_generated_open_pr_ids = issues.group_by(&:project).flat_map do |project, project_issues|
      paid_generated_pull_request_source_issue_ids(
        project: project,
        github_state: "open"
      ).where(issue_id: project_issues.map(&:id)).distinct.pluck(:issue_id)
    end.to_set

    in_progress_ids = active_run_ids | has_open_pr_ids | paid_generated_open_pr_ids
    eligible_ids = auto_pick_eligible_paid_state_scope(where(id: issue_ids)).pluck(:id).to_set

    issues.each_with_object({}) do |issue, hash|
      hash[issue.id] = if blocked_ids.include?(issue.id)
        :blocked
      elsif in_progress_ids.include?(issue.id)
        :in_progress
      elsif eligible_ids.include?(issue.id)
        :eligible
      else
        :blocked
      end
    end
  end

  AUTO_PICK_CLOSED_PR_CORRELATED_SUBQUERY = <<~SQL.squish.freeze
    SELECT 1 FROM issues closed_prs
    INNER JOIN projects closed_pr_projects
      ON closed_pr_projects.id = closed_prs.project_id
    WHERE closed_prs.project_id = agent_runs.project_id
      AND closed_prs.github_number = agent_runs.pull_request_number
      AND (
        closed_prs.github_html_url = agent_runs.pull_request_url
        OR (
          closed_prs.github_html_url IS NULL
          AND agent_runs.pull_request_url = CONCAT(
            'https://github.com/',
            closed_pr_projects.owner,
            '/',
            closed_pr_projects.repo,
            '/pull/',
            closed_prs.github_number
          )
        )
      )
      AND closed_prs.is_pull_request = TRUE
      AND closed_prs.github_state = 'closed'
      AND closed_prs.pr_review_phase IS DISTINCT FROM 'merged'
  SQL

  # Counterpart to AUTO_PICK_CLOSED_PR_CORRELATED_SUBQUERY for the merged-PR
  # evidence path: matches an agent_run's pull_request_number to a merged PR
  # row in the same project through the github_html_url/pull_request_url
  # repository-qualified join (with the null-URL fallback to the project's
  # owner/repo URL). Without this correlation, a run whose fork PR #42 is
  # unmerged would be treated as terminal evidence by an upstream-synced PR
  # #42 in the same project — same fork/upstream number-collision hazard
  # that Issue.paid_generated_pull_request_source_issue_ids
  # (app/models/issue.rb:685) explicitly guards against.
  AUTO_PICK_MERGED_PR_CORRELATED_SUBQUERY = <<~SQL.squish.freeze
    SELECT 1 FROM agent_runs merged_evidence_runs
    INNER JOIN issues merged_prs
      ON merged_prs.project_id = merged_evidence_runs.project_id
     AND merged_prs.github_number = merged_evidence_runs.pull_request_number
    INNER JOIN projects merged_pr_projects
      ON merged_pr_projects.id = merged_prs.project_id
     AND (
       merged_prs.github_html_url = merged_evidence_runs.pull_request_url
       OR (
         merged_prs.github_html_url IS NULL
         AND merged_evidence_runs.pull_request_url = CONCAT(
           'https://github.com/',
           merged_pr_projects.owner,
           '/',
           merged_pr_projects.repo,
           '/pull/',
           merged_prs.github_number
         )
       )
     )
    WHERE merged_evidence_runs.project_id = issues.project_id
      AND merged_evidence_runs.issue_id = issues.id
      AND merged_evidence_runs.goal = 'create_pr'
      AND merged_evidence_runs.pull_request_number IS NOT NULL
      AND merged_prs.is_pull_request = TRUE
      AND merged_prs.pr_review_phase = 'merged'
  SQL

  # GitHub's open state, not Paid's internal workflow state, determines
  # whether an issue can be considered. Callers apply the durable safeguards
  # (active runs, dependencies, labels, and pauses) around this shared scope.
  def self.auto_pick_eligible_paid_state_scope(base_scope) # @spec AUTO-PICK-QUEUE-005 AUTO-PICK-QUEUE-008
    base_scope
  end

  def self.open_pull_request_parent_issue_ids(project: nil, issue_ids: nil)
    scope = where(is_pull_request: true, github_state: "open").where.not(parent_issue_id: nil)
    scope = scope.where(project: project) if project
    scope = scope.where(parent_issue_id: issue_ids) if issue_ids
    scope.select(:parent_issue_id)
  end

  # Source issues whose implementation run recorded a PR that is currently
  # open. This is independent of parent_issue_id so a missed sync link
  # cannot authorize a duplicate implementation run, and independent of the
  # run's terminal status so a run that fails or is cancelled after
  # publishing still counts as source evidence.
  def self.open_paid_generated_pull_request_source_issue_ids(project:)
    paid_generated_pull_request_source_issue_ids(project: project, github_state: "open")
  end

  def self.merged_paid_generated_pull_request_source_issue_ids(project:)
    paid_generated_pull_request_source_issue_ids(project: project, pr_review_phase: "merged")
  end

  # A pull_request_number is persisted only once the PR exists on GitHub
  # (reserved at publication or recorded at completion), so it — not the
  # run's terminal status — is the produced-PR evidence. The GitHub URL is
  # the repository-qualified key: PR numbers collide between a fork and its
  # upstream repository.
  def self.paid_generated_pull_request_source_issue_ids(project:, **conditions)
    AgentRun.joins(<<~SQL.squish)
      INNER JOIN issues pull_requests
        ON pull_requests.project_id = agent_runs.project_id
        AND pull_requests.github_number = agent_runs.pull_request_number
      INNER JOIN projects pull_request_projects
        ON pull_request_projects.id = pull_requests.project_id
        AND (
          pull_requests.github_html_url = agent_runs.pull_request_url
          OR (
            pull_requests.github_html_url IS NULL
            AND agent_runs.pull_request_url = CONCAT(
              'https://github.com/',
              pull_request_projects.owner,
              '/',
              pull_request_projects.repo,
              '/pull/',
              pull_requests.github_number
            )
          )
        )
    SQL
      .where(project: project, goal: "create_pr")
      .where.not(issue_id: nil)
      .where.not(pull_request_number: nil)
      .where(pull_requests: { is_pull_request: true, **conditions })
      .select(:issue_id)
  end
  private_class_method :paid_generated_pull_request_source_issue_ids
  # Returns a Hash mapping issue_id => the most recently updated open
  # paid-generated pull request (an Issue row with is_pull_request: true).
  # A PR is "paid-generated" when an AgentRun in the same project produced
  # it (AgentRun#pull_request_number matches the PR issue's github_number).
  # Views and controllers precompute this hash once per request so per-issue
  # renders can look up the PR without re-querying (fixes the partial N+1
  # that would otherwise fire for each rendered issue with an open paid PR).
  # `pull_request_number` alone is not a safe join key: GitHub PR numbers are
  # per-repo, so a fork PR and an upstream-synced PR (Issue rows in the same
  # project, distinguished only by `source`) can share a number. The
  # persisted `pull_request_url` on the agent_run and the Issue's stored
  # `github_html_url` are the real, repo-qualified GitHub URL, so matching on
  # that instead of the bare number keeps fork and upstream PRs distinct.
  def self.open_paid_generated_prs_by_issue_id(project:, issue_ids:)
    issue_ids = Array(issue_ids).compact
    return {} if issue_ids.empty?

    issue_pr_pairs = project.agent_runs
      .where(issue_id: issue_ids)
      .where.not(pull_request_number: nil)
      .distinct
      .pluck(:issue_id, :pull_request_number, :pull_request_url)
    return {} if issue_pr_pairs.empty?

    pr_numbers = issue_pr_pairs.map { |(_issue_id, pr_number, _pr_url)| pr_number }.uniq
    open_prs_by_url = project.issues
      .pull_requests_only
      .where(github_state: "open", github_number: pr_numbers)
      .index_by(&:github_url)
    return {} if open_prs_by_url.empty?

    recency = ->(pr) { [ pr.github_updated_at || Time.at(0), pr.updated_at || Time.at(0) ] }

    issue_pr_pairs.each_with_object({}) do |(issue_id, _pr_number, pr_url), result|
      pr = open_prs_by_url[pr_url]
      next unless pr

      existing = result[issue_id]
      result[issue_id] = pr if existing.nil? || (recency.call(pr) <=> recency.call(existing)) == 1
    end
  end

  # Returns the open paid-generated pull request (an Issue with
  # is_pull_request: true) associated with this issue, if any. Prefers the
  # most recently updated one when multiple exist. Intended for single-issue
  # controller checks; for rendering collections, use
  # .open_paid_generated_prs_by_issue_id to avoid per-row queries.
  def associated_paid_pull_request
    return nil if is_pull_request?
    return nil unless project_id && id

    self.class.open_paid_generated_prs_by_issue_id(project: project, issue_ids: [ id ])[id]
  end

  def invalidate_pr_progress_state_cache!
    # Progress is derived from agent-run history, so Issue-level memoization
    # would go stale whenever runs change while the same Issue instance is
    # still in memory. Keep the compatibility hook, but make it a no-op.
    nil
  end

  private

  def inbox_count_cache_invalidation_needed?
    saved_change_to_needs_input_since? ||
      saved_change_to_manual_review_started_at? ||
      saved_change_to_runner_retry_abandoned_at? ||
      saved_change_to_closeout_resolved_at? ||
      waiting_issue_github_state_changed? ||
      retry_limited_issue_github_state_changed? ||
      merge_approval_candidate_state_changed?
  end

  def bump_inbox_cache_version
    Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
  end

  def waiting_issue_github_state_changed?
    saved_change_to_github_state? && paid_state.in?(%w[needs_input manual_review])
  end

  # Mirror of waiting_issue_github_state_changed? for the retry_limited lane:
  # the Inbox query filters `github_state: "open"` regardless of paid_state,
  # so a close/reopen on a runner-retry-abandoned issue must also bump the
  # cached badge count (OPERATOR-INBOX-002E).
  def retry_limited_issue_github_state_changed?
    saved_change_to_github_state? && runner_retry_abandoned_at.present?
  end

  def merge_approval_candidate_state_changed?
    is_pull_request? && (
      saved_change_to_auto_merge_blockers? ||
      saved_change_to_auto_merge_evaluated_at? ||
      saved_change_to_awaiting_approval_since? ||
      saved_change_to_merge_permission_rejected_at? ||
      saved_change_to_pr_review_phase? ||
      saved_change_to_github_state?
    )
  end

  # Every counter an escalation accumulated, plus the markers that tell
  # PullRequests::ProgressState to stop counting failures from before the
  # owner intervened.
  def escalation_counter_reset_attributes
    reset_at = Time.current
    {
      draft_review_count: 0,
      pr_followup_count: 0,
      review_goal_retry_count: 0,
      stuck_confirmation_count: 0,
      review_goal_retry_reset_at: reset_at,
      operational_failure_reset_at: reset_at
    }
  end

  CLOSING_KEYWORD_RE = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b/i
  CLOSING_REF_RE = /\G\s*(?:,\s*)?(?:and\s+)?(?:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)|(?<!\w))#(\d+)/

  # Parses closing issue references that immediately follow a closing keyword,
  # consuming only chained references (separated by "," or "and"). Stops at the
  # first non-reference token so that e.g. "Closes #12, related to #14" only
  # returns [12].
  def parse_closing_references
    return [] if body.blank?

    numbers = []
    text = body.to_s
    text.scan(CLOSING_KEYWORD_RE) do
      pos = Regexp.last_match.end(0)
      # Skip optional colon after keyword (e.g. "Fixes: #123", "Closes: #123")
      pos += 1 if text[pos] == ":"
      while (m = CLOSING_REF_RE.match(text, pos))
        owner, repo, number = m[1], m[2], m[3]
        same_repo_reference =
          (owner.blank? || owner.casecmp?(project.owner)) &&
          (repo.blank? || repo.casecmp?(project.repo))

        numbers << number.to_i if same_repo_reference
        pos = m.end(0)
      end
    end
    numbers.uniq
  end

  def parent_issue_belongs_to_same_project
    return if parent_issue.project_id == project_id

    errors.add(:parent_issue, "must belong to the same project")
  end

  def stamp_paused_at
    self.paused_at = Time.current
  end

  def sync_parent_issue_linked_at
    self.parent_issue_linked_at = parent_issue_id.present? ? Time.current : nil
  end

  def stamp_parent_issue_linked_at
    self.parent_issue_linked_at ||= Time.current
  end

  # Stamps `closed_at` when `github_state` transitions to "closed" so the epic
  # re-audit eligibility check can compare the *resolution* time against the
  # audit's terminal timestamp instead of the (potentially mid-run) link
  # timestamp. `parent_issue_linked_at` is deliberately distinct: it captures
  # when the relationship was first observed, which can fall mid-run for work
  # an epic audit filed itself; `closed_at` is only stamped on the actual
  # open -> closed transition. Cleared on a reopen so a subsequent re-closure
  # re-arms correctly. Distinct from `github_updated_at`/`updated_at`, both of
  # which are bumped by unrelated label/comment syncs and would re-arm the
  # umbrella on any metadata change.
  def sync_closed_at
    if github_state == "closed"
      self.closed_at ||= Time.current
    elsif github_state_was == "closed"
      self.closed_at = nil
    end
  end

  # Mirrors the new `paused` value onto GitHub by adding/removing the
  # `paid-paused` label. No-op when there is no project client (e.g. a
  # project without a configured GitHub credential); the next sync then
  # reconciles the label from the GitHub side. Also a no-op for synthetic
  # issues (code-scanning/Dependabot alerts): those have a synthetic
  # github_number with no backing GitHub issue, so pushing a label would
  # 404. The local `paused` flag still excludes them from auto-pick.
  #
  # Also a no-op for upstream projects: the issue was synced from a
  # repository Paid does not own, and `project.full_name` (the fork) is
  # not the GitHub issue's actual home. Pushing the label there would
  # either 404 (no fork issue at that number) or, worse, modify a
  # different fork issue that happens to share the upstream issue's
  # number — violating the read-only contract for upstream work items
  # (UPSTREAM-ISSUE-004). The local `paused` flag still excludes the
  # issue from auto-pick until the next sync reflects upstream state.
  # @spec UPSTREAM-ISSUE-004
  def sync_paused_label_to_github
    return if destroyed?
    return unless github_number
    return unless source == GITHUB_SOURCE
    return if project&.upstream_pr_target?

    client = project&.client
    return unless client

    if paused
      client.add_labels_to_issue(project.full_name, github_number, [ PAUSED_LABEL ])
    else
      client.remove_label_from_issue(project.full_name, github_number, PAUSED_LABEL)
    end
  rescue GithubClient::NotFoundError
    # Removing a label that is already absent — desired state achieved.
    # Only suppress when unpausing; a 404 on add_labels_to_issue is unexpected.
    raise if paused
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "github_sync.sync_paused_label_failed",
      issue_id: id,
      issue_number: github_number,
      paused: paused,
      error: e.message
    )
  end

  # During bulk sync (e.g. FetchIssuesActivity), this fires per-issue, but the
  # atomic WHERE clause ensures only the issue with the latest github_updated_at
  # actually modifies the project row — the rest are cheap no-op index lookups.
  def update_project_last_github_activity_at
    return unless github_updated_at_previously_changed?

    Project
      .where(id: project_id)
      .where("last_github_activity_at IS NULL OR last_github_activity_at < ?", github_updated_at)
      .update_all(last_github_activity_at: github_updated_at, updated_at: Time.current)
  end

  def broadcast_current_section
    if is_pull_request?
      project.broadcast_pull_requests_update
      project.broadcast_issues_update if parent_issue_id.present?
    else
      project.broadcast_issues_update
    end
  end

  def broadcast_changed_sections
    if saved_change_to_is_pull_request?
      project.broadcast_issues_update
      project.broadcast_pull_requests_update
    elsif is_pull_request?
      project.broadcast_pull_requests_update
      project.broadcast_issues_update if saved_change_to_parent_issue_id?
    else
      project.broadcast_issues_update
    end
  end

  def github_just_closed?
    saved_change_to_github_state? && github_state == "closed"
  end

  # An issue that just finished (paid_state -> completed) or was closed on
  # GitHub will never need the agent runs still sitting unclaimed in its queue:
  # those runs target work that is already done. Nothing else cancels them, so
  # they leak as permanently "queued" rows (observed: create_pr runs stuck 17+
  # days, each also holding a unique-active-run slot for its issue).
  def work_no_longer_needed?
    (saved_change_to_paid_state? && paid_state == "completed") || github_just_closed?
  end

  # Cancel only unclaimed runs (no Temporal workflow yet) — claimed/running
  # runs are mid-flight and handled by the normal lifecycle. Reviews are
  # PR-scoped rather than issue-scoped, so they keep their own retry/limit
  # handling and are left alone.
  def cancel_orphaned_queued_runs
    reason = "Issue resolved (paid_state=#{paid_state}, github_state=#{github_state}); " \
             "unclaimed queued run no longer needed"

    agent_runs.waiting.where.not(goal: "review").find_each do |run|
      # Re-check under the row lock: AgentRun.claim_next_queued_run can claim
      # this run (status still "queued", temporal_workflow_id -> CLAIMED_SENTINEL)
      # in the window between the scope query and here. cancel! only guards on
      # finished?, so without this check we would mark a just-claimed run
      # cancelled while its workflow/container start up — the exact orphan this
      # callback exists to prevent. Skip it; the normal lifecycle owns it now.
      cancelled = run.with_lock do
        next false unless run.status == "queued" && run.temporal_workflow_id.nil?

        run.cancel!(error: reason)
      end

      next unless cancelled

      Rails.logger.info(
        message: "agent_run.cancelled_issue_resolved",
        issue_id: id,
        issue_number: github_number,
        project_id: project_id,
        agent_run_id: run.id,
        goal: run.goal,
        paid_state: paid_state
      )
    rescue => e
      Rails.logger.error(
        message: "agent_run.cancel_orphaned_failed",
        issue_id: id,
        agent_run_id: run.id,
        error: e.message
      )
    end
  end

  def enqueue_newly_unblocked_dependents # @spec EAGER-QUEUE-004
    auto_pick_enabled_dependents.find_each do |dependent|
      next unless Issues::AutoPickProjectGate.call(dependent.project)
      next unless Issue.ready_for_work(dependent.project).where(id: dependent.id).exists?

      Rails.logger.info(
        message: "enqueue_eligible.dependency_resolved",
        blocker_issue_id: id,
        blocker_issue_number: github_number,
        dependent_issue_id: dependent.id,
        dependent_issue_number: dependent.github_number,
        project_id: dependent.project_id
      )

      Issues::EnqueueEligible.call(dependent, project: dependent.project, skip_project_gate: true)
    rescue => e
      Rails.logger.error(
        message: "enqueue_eligible.dependency_resolution_failed",
        issue_id: id,
        dependent_issue_id: dependent.id,
        error: e.message
      )
    end
  end

  def auto_pick_enabled_dependents
    dependency_dependents = Issue
      .includes(:project)
      .joins(:project)
      .where(id: reverse_issue_dependencies.select(:issue_id), projects: { auto_pick_enabled: true })
    # Only a non-PR child close feeds the partial-completion re-arm path:
    # queue admission's `child_times` resolution intentionally excludes PRs
    # (the merged tracking PR is not authoritative prerequisite evidence —
    # AUTO-PICK-QUEUE-012), so a closing tracking PR must not alone or
    # together trigger a re-arm of its parent here.
    partial_completion_parents = if parent_issue_id.present? && !is_pull_request?
      Issue
        .includes(:project)
        .joins(:project)
        .where(id: parent_issue_id, projects: { auto_pick_enabled: true })
        .where.not(partial_completion_at: nil)
    else
      Issue.none
    end

    dependency_dependents.or(partial_completion_parents)
  end

  # See the after_update_commit hook that calls this: when the issue just
  # closed on GitHub, any active partial-closeout prerequisite notification
  # is stale. Resolve every active notification for the issue under that
  # source so reopening the issue starts from a clean notification state.
  def resolve_partial_closeout_prerequisite_notifications # @spec NO-OUTPUT-ISSUE-007
    Notification.where(
      account_id: project&.account_id,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      subject_type: "Issue",
      subject_id: id,
      resolved_at: nil,
      dismissed_at: nil
    ).find_each do |notification|
      Notifications::Resolve.call(
        account: notification.account,
        source: notification.source,
        subject: notification.subject,
        user: notification.user
      )
    end
  rescue => e
    Rails.logger.error(
      message: "notifications.partial_closeout_prerequisite_resolve_failed",
      issue_id: id,
      error: e.message
    )
  end

  def auto_pick_recheck_needed?
    return false if is_pull_request?
    return false unless saved_change_to_paid_state?
    return false unless project&.auto_pick_enabled?

    paid_state.in?(%w[new planning failed completed analyzed])
  end

  def enqueue_self_if_became_auto_pick_eligible # @spec EAGER-QUEUE-007
    wait = auto_pick_reenqueue_delay
    job = Issues::ReenqueueEligibleJob

    if wait
      job.set(wait: wait).perform_later(id)
    else
      job.perform_later(id)
    end

    Rails.logger.info(
      message: "enqueue_eligible.issue_state_changed",
      issue_id: id,
      issue_number: github_number,
      project_id: project_id,
      paid_state: paid_state,
      wait_seconds: wait&.to_i
    )
  end

  # Sidekiq's retry curve: (n ** 4) + 15 + jitter seconds, where n is the
  # zero-indexed retry attempt (n=0 is the first retry, after the first
  # failure). Lenient on the first few retries (~20s, ~26s, ~46s, ~2m, ~5m)
  # then grows quickly (~11m, ~22m, ~41m at n=5-7) and keeps growing — at
  # n=24 the delay is ~3.8 days, at n=49 it's ~72 days. See
  # https://github.com/sidekiq/sidekiq/wiki/Error-Handling#automatic-job-retry.
  def auto_pick_reenqueue_delay # @spec EAGER-QUEUE-007
    return unless paid_state == "failed"
    return issue_analysis_reenqueue_delay if issue_analysis_backoff_active?

    n = [ consecutive_auto_pick_failure_count - 1, 0 ].max
    ((n**4) + 15 + (rand(10) * (n + 1))).seconds
  end

  # Counts the most recent consecutive failed/no_output auto-pick runs.
  # Bounded at 50 so the retry curve can keep growing past the ~2-hour
  # mark (n=10 produces ~3h, n=49 produces ~72 days) without scanning
  # an unbounded number of historical runs. A 51st consecutive failure
  # is treated the same as the 50th.
  def consecutive_auto_pick_failure_count
    statuses = agent_runs
      .where(auto_pick: true, goal: %w[create_pr analyze_issue])
      .finished
      .order(created_at: :desc, id: :desc)
      .limit(50)
      .pluck(:status)

    statuses.take_while { |status| (AgentRun::FAILURE_STATUSES + %w[no_output]).include?(status) }.count
  end

  public

  def issue_analysis_backoff_active?(reset_at: nil, now: Time.current) # @spec ISSUE-ANALYSIS-010 AUTO-PICK-QUEUE-002
    return false if issue_analysis_next_attempt_at.blank? || issue_analysis_next_attempt_at <= now
    return false if reset_at.present? && issue_analysis_backoff_set_at.present? && issue_analysis_backoff_set_at < reset_at

    true
  end

  def record_issue_analysis_backoff!(paid_state:, now: Time.current) # @spec ISSUE-ANALYSIS-010
    streak = consecutive_issue_analysis_provider_exhaustion_count
    next_attempt_at = now + issue_analysis_backoff_delay(streak)
    attrs = {
      issue_analysis_next_attempt_at: next_attempt_at,
      issue_analysis_backoff_set_at: now
    }
    attrs[:paid_state] = paid_state if self.paid_state != paid_state
    update!(attrs)

    Rails.logger.info(
      message: "issue.issue_analysis_backoff_recorded",
      component: "agent_execution",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      next_attempt_at: next_attempt_at.iso8601,
      consecutive_failures: streak
    )

    next_attempt_at
  end

  def clear_issue_analysis_backoff!(reason: "Cleared after a successful issue-analysis provider call") # @spec ISSUE-ANALYSIS-010 ISSUE-ANALYSIS-011
    return if issue_analysis_next_attempt_at.blank? && issue_analysis_backoff_set_at.blank?

    update!(issue_analysis_next_attempt_at: nil, issue_analysis_backoff_set_at: nil)

    Rails.logger.info(
      message: "issue.issue_analysis_backoff_cleared",
      component: "agent_execution",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      reason: reason
    )
  end

  # An issue is abandoned for retry-cap purposes once every available provider
  # has hit the per-issue per-provider retry cap. Abandoned issues are excluded
  # from auto-pick (see DefaultCandidateSource) until the abandonment is cleared.
  # See {#clear_runner_retry_abandonment!} for how clearing interacts with the
  # per-provider failure counts that tripped the cap.
  def runner_retry_abandoned?
    runner_retry_abandoned_at.present?
  end

  # Marks the issue as abandoned due to the retry cap. Idempotent for an active
  # abandonment, while retaining the number of distinct entries into the lane.
  # @spec OPERATOR-INBOX-002F
  def abandon_due_to_runner_retry_cap!(reason:, cap:, runner_keys:)
    return if runner_retry_abandoned_at.present?

    update!(
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: reason,
      runner_retry_abandonment_count: runner_retry_abandonment_count + 1
    )

    Rails.logger.info(
      message: "issue.runner_retry_abandoned",
      component: "agent_execution",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      retry_cap: cap,
      runner_keys: Array(runner_keys),
      reason: reason
    )
  end

  # Clears the abandonment flag so a successful manual run (or an operator's
  # explicit "Re-enable" from the inbox) can re-enter auto-pick. Also stamps
  # runner_retry_failure_window_reset_at, which {AgentRuns::IssueRunnerFailureHistory}
  # treats as a lower bound on the agent runs it counts — so prior failures that
  # tripped the cap no longer count toward it after this clear. Without that, an
  # operator's explicit "try again" would be defeated on the very next dispatch:
  # every provider would still be over the (unreset) cap and the issue would be
  # instantly re-abandoned, gathering no new information (#4092).
  #
  # +window_reset_at+ defaults to the clear time (operator-triggered clears have
  # no run to anchor to). The automatic clear on a successful run instead passes
  # that run's +created_at+: the reset window is a lower bound on AgentRun rows
  # (see {AgentRuns::IssueRunnerFailureHistory#prior_runs}), so stamping "now"
  # would exclude the triggering run itself — including any failed fallback
  # attempts (e.g. claude failing before codex succeeds) it already recorded in
  # the same run's runners_attempted before this clear ran.
  # @spec OPERATOR-INBOX-002G
  def clear_runner_retry_abandonment!(reason: "Cleared after a successful run", window_reset_at: Time.current)
    return unless runner_retry_abandoned_at.present?

    update!(
      runner_retry_abandoned_at: nil,
      runner_retry_abandon_reason: nil,
      runner_retry_failure_window_reset_at: window_reset_at
    )

    Rails.logger.info(
      message: "issue.runner_retry_abandonment_cleared",
      component: "agent_execution",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      reason: reason
    )
  end

  def closeout_resolved?
    closeout_resolved_at.present?
  end

  # Records the operator's attestation that the recorded closeout evidence
  # (merged partial PR / no-code outcome) completes this issue. The digest
  # scopes the dismissal to one evidence generation: newer terminal evidence
  # re-surfaces the partial_closeout inbox entry, and repeated GitHub sync
  # cannot recreate the suppressed item because sync writes no state here.
  # Deliberately does NOT write to GitHub — the issue stays open there for a
  # human to close; Paid only stops surfacing it.
  # @spec PARTIAL-CLOSEOUT-006
  def resolve_closeout!(actor:, evidence_digest:)
    update!(
      paid_state: "completed",
      closeout_resolved_at: Time.current,
      closeout_resolution_digest: evidence_digest,
      closeout_resolved_by: actor
    )

    Rails.logger.info(
      message: "issue.closeout_resolved",
      component: "agent_execution",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      resolved_by_id: actor&.id
    )
  end

  private

  def issue_analysis_reenqueue_delay
    [ issue_analysis_next_attempt_at - Time.current, 0 ].max.seconds
  end

  def issue_analysis_backoff_delay(streak = consecutive_issue_analysis_provider_exhaustion_count)
    multiplier = [ streak - 1, 0 ].max
    [ ISSUE_ANALYSIS_BACKOFF_BASE_DELAY * (2**multiplier), ISSUE_ANALYSIS_BACKOFF_MAX_DELAY ].min
  end

  # Counts recent automatic `analyze_issue` runs whose failure should grow the
  # ISSUE-ANALYSIS-010 backoff. Excludes `rate_limited` runs because those are
  # handled by the separate in-place recovery path from ISSUE-ANALYSIS-006
  # (StaleRunDetectorJob re-queues the run once `rate_limited_until` elapses);
  # mixing them into this streak would let a single prior rate-limited run push
  # the first actual exhaustion failure from a 5-minute delay to a 10-minute
  # delay (multiplier 0 -> 1) even though no exhaustion has happened yet.
  def consecutive_issue_analysis_provider_exhaustion_count
    agent_runs
      .where(auto_pick: true, goal: "analyze_issue")
      .where.not(status: "rate_limited")
      .finished
      .order(created_at: :desc, id: :desc)
      .limit(ISSUE_ANALYSIS_BACKOFF_HISTORY_LIMIT)
      .take_while(&:provider_unavailable?)
      .count
  end

  public

  # Prefix used to distinguish a terminal push-permission abandonment from a
  # retry-cap abandonment in the free-text +runner_retry_abandon_reason+ field.
  PUSH_PERMISSION_ABANDON_PREFIX = "Push rejected:".freeze

  # True when this issue was parked from auto-pick because a push was rejected
  # for a permission the GitHub App installation token lacks (e.g. a change
  # under .github/workflows/ needing the workflows permission). Distinct from
  # +runner_retry_abandoned?+ (every-runner-capped) for UI surfacing, but
  # shares the same "not auto-pickable until cleared" gate.
  def push_permission_abandoned?
    runner_retry_abandoned? &&
      runner_retry_abandon_reason.to_s.start_with?(PUSH_PERMISSION_ABANDON_PREFIX)
  end

  # Parks the issue from auto-pick after a terminal push-permission rejection.
  # A GitHub App lacking the needed permission fails identically on every retry,
  # so re-enqueuing only wastes runs. Reuses the runner_retry_abandoned_at gate
  # (already filtered out of auto-pick and cleared on a successful manual run).
  # Idempotent: a no-op when the issue is already abandoned.
  # @spec OPERATOR-INBOX-002F
  def abandon_due_to_push_permission_rejection!(reason:)
    reason = "#{PUSH_PERMISSION_ABANDON_PREFIX} #{reason}" unless reason.to_s.start_with?(PUSH_PERMISSION_ABANDON_PREFIX)
    return if runner_retry_abandoned_at.present?

    update!(
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: reason,
      runner_retry_abandonment_count: runner_retry_abandonment_count + 1
    )

    Rails.logger.info(
      message: "issue.push_permission_abandoned",
      component: "github_integration",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      reason: reason
    )
  end

  # How long MergePullRequestActivity waits before re-attempting a merge after
  # a GitHub App permission rejection (e.g. missing `workflows` permission for
  # a change under .github/workflows/). Unlike the push-permission rejection
  # above, merge attempts are re-triggered by every poll cycle rather than by
  # a bounded set of agent-run retries, so a hard one-time abandon would
  # either loop forever (if unchecked) or require a manual clear step once the
  # App's permissions are fixed. A rolling cooldown self-heals automatically
  # once the permission is granted, while still cutting retry volume from
  # every poll cycle down to once per cooldown window.
  MERGE_PERMISSION_RETRY_COOLDOWN = 6.hours

  def merge_permission_rejected?
    merge_permission_rejected_at.present?
  end

  # True once per cooldown window, so MergePullRequestActivity only re-attempts
  # (and re-checks whether the underlying permission was fixed) periodically
  # instead of on every poll cycle.
  def merge_permission_retry_due?
    !merge_permission_rejected? || merge_permission_rejected_at <= MERGE_PERMISSION_RETRY_COOLDOWN.ago
  end

  # Records a terminal merge-time GitHub App permission rejection. Always
  # refreshes the timestamp (unlike the push-permission abandon, this is not
  # idempotent-once) so the cooldown window restarts from the latest attempt.
  def record_merge_permission_rejection!(reason:)
    update!(merge_permission_rejected_at: Time.current, merge_permission_rejection_reason: reason)

    Rails.logger.info(
      message: "issue.merge_permission_rejected",
      component: "github_integration",
      issue_id: id,
      project_id: project_id,
      issue_number: github_number,
      reason: reason
    )
  end
end
