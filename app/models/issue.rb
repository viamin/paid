# frozen_string_literal: true

class Issue < ApplicationRecord
  PAID_STATES = %w[new planning in_progress completed failed needs_input recommend_close analyzed].freeze
  PR_REVIEW_PHASES = %w[draft restarted ready merged escalated].freeze

  # Constants for synthetic alert issues. Shared with
  # Activities::ScanSecurityAlertsActivity which creates these issues.
  GITHUB_SOURCE = "github"
  SYNTHETIC_CODE_SCANNING_SOURCE = "code_scanning_alert"
  # Legacy source kept in VALID_SOURCES so existing Dependabot rows pass
  # validation on update (e.g. from agent-run completion activities).
  DEPENDABOT_ALERT_SOURCE = "dependabot_alert"
  VALID_SOURCES = [ GITHUB_SOURCE, SYNTHETIC_CODE_SCANNING_SOURCE, DEPENDABOT_ALERT_SOURCE ].freeze
  SEVERITY_ORDER = %w[critical high medium low].freeze
  SEVERITY_TO_PRIORITY = { "critical" => "P1", "high" => "P1", "medium" => "P2", "low" => "P3" }.freeze
  TRACKER_PATTERN = /\b(?:tracker|remaining\s+work|completion\s+criteria|phase\s+tracker|meta\s+issue)\b/i
  # Body match requires the tracker vocabulary to appear inside a markdown
  # heading (e.g. "## Tracker", "## Remaining Work"). Matching anywhere in
  # the body produced false positives for feature issues that incidentally
  # mention "tracker" in prose (e.g. "support custom issue trackers",
  # "deploy tracker"), which then got permanently excluded from auto-pick
  # by the "tracker with no body refs" safety net in Issues::AutoPick.
  TRACKER_BODY_HEADING_PATTERN = /^[#]{1,6}\s+.*\b(?:tracker|remaining\s+work|completion\s+criteria|phase\s+tracker|meta\s+issue)\b/i
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
  has_many :issue_merge_subscriptions, dependent: :destroy

  has_many :issue_dependencies, dependent: :destroy
  has_many :dependencies, through: :issue_dependencies, source: :depends_on_issue
  has_many :reverse_issue_dependencies, class_name: "IssueDependency",
                                        foreign_key: :depends_on_issue_id,
                                        dependent: :destroy,
                                        inverse_of: :depends_on_issue
  has_many :dependents, through: :reverse_issue_dependencies, source: :issue

  validates :github_issue_id, presence: true, uniqueness: { scope: :project_id }
  validates :github_number, presence: true
  validates :title, presence: true, length: { maximum: 1000 }
  validates :github_state, presence: true
  validates :github_creator_login, presence: true
  validates :github_created_at, presence: true
  validates :github_updated_at, presence: true
  validates :paid_state, presence: true, inclusion: { in: PAID_STATES }
  before_validation { self.source ||= GITHUB_SOURCE }
  validates :source, presence: true, inclusion: { in: VALID_SOURCES }
  validates :pr_review_phase, inclusion: { in: PR_REVIEW_PHASES }, if: :is_pull_request?
  validates :enhance_issue_rounds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :parent_issue_belongs_to_same_project, if: -> { parent_issue.present? }

  after_commit :broadcast_current_section, on: [ :create, :destroy ]
  after_update_commit :broadcast_changed_sections
  after_update_commit :enqueue_newly_unblocked_dependents, if: :github_just_closed?
  after_update_commit :enqueue_self_if_became_auto_pick_eligible, if: :auto_pick_recheck_needed?
  after_commit :update_project_last_github_activity_at, on: [ :create, :update ]

  scope :by_paid_state, ->(state) { where(paid_state: state) }
  scope :root_issues, -> { where(parent_issue_id: nil) }
  scope :sub_issues_only, -> { where.not(parent_issue_id: nil) }
  scope :issues_only, -> { where(is_pull_request: false) }
  scope :pull_requests_only, -> { where(is_pull_request: true) }
  scope :auto_continue_active, -> { where(auto_continue_paused: false) }
  scope :ready_for_work, ->(project) {
    # Match blocking_issues / lifecycle_statuses semantics: open dependencies
    # excluding recommend_close (treated as effectively resolved pending
    # human confirmation, so they should not gate downstream work).
    blocked_by_local_open = IssueDependency
      .joins(:issue, :depends_on_issue)
      .where(
        depends_on_issue: { github_state: "open" },
        issues: { project_id: project.id }
      )
      .where.not(depends_on_issue: { paid_state: "recommend_close" })
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

    where(project: project, github_state: "open", is_pull_request: false)
      .where.not(id: blocked_by_local_open)
      .where.not(id: blocked_by_local_deployment_pending)
      .where.not(id: blocked_by_external)
  }

  def github_url
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

    path = is_pull_request? ? "pull" : "issues"
    "#{project.github_url}/#{path}/#{github_number}"
  end

  def has_label?(label)
    labels.include?(label)
  end

  def trusted?
    project.trusted_github_user?(github_creator_login)
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
  def pr_progress_state(current_head_sha: nil, current_head_updated_at: nil)
    PullRequests::ProgressState.call(
      project:, issue: self,
      current_head_sha:, current_head_updated_at:
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

  def pr_stuck?(limit:, stale_after:, **kwargs)
    pr_progress_state(**kwargs).stuck?(limit:, stale_after:)
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

  def reset_review_goal_retry_breaker!
    reset_at = Time.current

    update!(
      pr_review_phase: "ready",
      review_goal_retry_count: 0,
      review_goal_retry_reset_at: reset_at,
      operational_failure_reset_at: reset_at
    )
  end

  def dismiss_escalation!(draft:)
    reset_at = Time.current
    attrs = {
      labels: labels - %w[paid-escalated paid-dismiss-escalation],
      pr_review_phase: draft ? "restarted" : "ready",
      pr_followup_count: 0,
      review_goal_retry_count: 0,
      review_goal_retry_reset_at: reset_at,
      operational_failure_reset_at: reset_at,
      ci_retry_requested_at: nil
    }
    attrs[:draft_review_count] = 0 if draft

    update!(attrs)
  end

  def ready_to_work?
    blocking_issues.none? &&
      blocking_deployment_dependencies.none? &&
      blocking_external_dependencies.none?
  end

  def blocking_issues
    dependencies.where(github_state: "open").where.not(paid_state: "recommend_close")
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
  def self.lifecycle_statuses(issues)
    issues = issues.to_a
    return {} if issues.empty?

    issue_ids = issues.map(&:id)

    # Match blocking_issues semantics: open dependencies excluding recommend_close
    blocked_by_local = IssueDependency
      .joins(:depends_on_issue)
      .where(issue_id: issue_ids, depends_on_issue: { github_state: "open" })
      .where.not(depends_on_issue: { paid_state: "recommend_close" })
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
    # the dep is satisfied when the target is closed (or parked at
    # recommend_close) in a sibling project of the same account. Grouped
    # by account_id because the issues collection may span tenants in
    # principle (it currently does not in the ProjectsController caller,
    # but the method does not enforce that).
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
    # dependency rule above by exempting recommend_close sub-issues.
    blocked_by_open_subissues = where(
      parent_issue_id: issue_ids,
      is_pull_request: false,
      github_state: "open"
    ).where.not(paid_state: "recommend_close")
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

    in_progress_ids = active_run_ids | has_open_pr_ids

    issues.each_with_object({}) do |issue, hash|
      hash[issue.id] = if blocked_ids.include?(issue.id)
        :blocked
      elsif in_progress_ids.include?(issue.id)
        :in_progress
      else
        :eligible
      end
    end
  end

  def self.open_pull_request_parent_issue_ids(project: nil, issue_ids: nil)
    scope = where(is_pull_request: true, github_state: "open").where.not(parent_issue_id: nil)
    scope = scope.where(project: project) if project
    scope = scope.where(parent_issue_id: issue_ids) if issue_ids
    scope.select(:parent_issue_id)
  end

  # Returns a Hash mapping issue_id => the most recently updated open
  # paid-generated pull request (an Issue row with is_pull_request: true).
  # A PR is "paid-generated" when an AgentRun in the same project produced
  # it (AgentRun#pull_request_number matches the PR issue's github_number).
  # Views and controllers precompute this hash once per request so per-issue
  # renders can look up the PR without re-querying (fixes the partial N+1
  # that would otherwise fire for each rendered issue with an open paid PR).
  def self.open_paid_generated_prs_by_issue_id(project:, issue_ids:)
    issue_ids = Array(issue_ids).compact
    return {} if issue_ids.empty?

    issue_pr_pairs = project.agent_runs
      .where(issue_id: issue_ids)
      .where.not(pull_request_number: nil)
      .distinct
      .pluck(:issue_id, :pull_request_number)
    return {} if issue_pr_pairs.empty?

    pr_numbers = issue_pr_pairs.map(&:last).uniq
    open_prs_by_number = project.issues
      .pull_requests_only
      .where(github_state: "open", github_number: pr_numbers)
      .index_by(&:github_number)
    return {} if open_prs_by_number.empty?

    recency = ->(pr) { [ pr.github_updated_at || Time.at(0), pr.updated_at || Time.at(0) ] }

    issue_pr_pairs.each_with_object({}) do |(issue_id, pr_number), result|
      pr = open_prs_by_number[pr_number]
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

  def enqueue_newly_unblocked_dependents
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
    Issue
      .includes(:project)
      .joins(:project)
      .where(id: reverse_issue_dependencies.select(:issue_id), projects: { auto_pick_enabled: true })
  end

  def auto_pick_recheck_needed?
    return false if is_pull_request?
    return false unless saved_change_to_paid_state?
    return false unless project&.auto_pick_enabled?

    paid_state.in?(%w[new planning failed completed])
  end

  def enqueue_self_if_became_auto_pick_eligible
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
  def auto_pick_reenqueue_delay
    return unless paid_state == "failed"

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
end
