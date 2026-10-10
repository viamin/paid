# frozen_string_literal: true

module Inbox
  # Cheap, approximate count of the current user's inbox entries for the nav
  # badge. Unlike Inbox::Queue, this never loads issue bodies or parses
  # clarifying questions per candidate — it counts needs_input rows on the
  # operator's visible projects plus open plan reviews, cached for a short
  # TTL per user.
  # Questionless needs_input rows are invalid and repaired during sync, so
  # counting them here (without a question-presence check) is a deliberate,
  # bounded approximation rather than a rendering bug.
  class Count
    CACHE_TTL = 90.seconds
    DISPLAY_CAP = 99

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec OPERATOR-INBOX-010
    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute_count }
    end

    private

    attr_reader :user

    def compute_count
      needs_input_count + open_plan_review_count + merge_approval_count + action_required_count +
        escalated_pr_count + manual_review_count + intent_conformance_count + feature_decision_count +
        retry_limited_count + change_intent_draft_count + partial_closeout_count +
        test_review_pending_count
    end

    def needs_input_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, paid_state: "needs_input", github_state: "open").count
    end

    def open_plan_review_count
      PlanReviewPolicy::Scope.new(user, DecompositionDecision).resolve.open_plan_reviews.count
    end

    # @spec FEATURE-APPROVAL-013
    def feature_decision_count
      FeatureIntentPolicy::Scope.new(user, FeatureIntent).resolve
        .where(status: Inbox::Queue::FEATURE_DECISION_STATUSES)
        .count
    end

    def merge_approval_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      merge_approval_candidates(project_ids).count { |issue| Inbox::MergeApproval.call(issue).present? }
    end

    # Excludes notifications whose subject cannot be projected into a visible
    # inbox project. Runner-scoped blocking notifications borrow the owner's
    # first visible project so they can render in the queue without a
    # runner-specific inbox lane.
    def action_required_count
      notifications = NotificationPolicy::Scope.new(user, Notification).resolve.active.blocking
        .includes(:subject)
        .to_a
      Notification.preload_resolved_projects(notifications)
      preload_runner_users(notifications)
      notifications.count { |notification| project_for(notification).present? }
    end

    # Narrows to rows that could plausibly be approval-only blockers before
    # falling back to Ruby for the full Inbox::MergeApproval signal check,
    # so this stays a bounded scan instead of one Issue instantiation per
    # open, ready PR on the account.
    def merge_approval_candidates(project_ids)
      Issue
        .includes(:project)
        .where(
          project_id: project_ids,
          is_pull_request: true,
          github_state: "open",
          pr_review_phase: "ready",
          merge_permission_rejected_at: nil
        )
        .where.not(projects: { auto_merge_mode: "off" })
        .where(merge_approval_candidate_conditions)
    end

    # @spec AUTO-MERGE-009 INBOX-FOUNDATION-008
    # A structured hold is actionable before the scanner persists a blocker
    # snapshot and does not depend on a configured owner reviewer.
    def merge_approval_candidate_conditions
      Issue.sanitize_sql_array([
        "issues.labels @> :hold_label::jsonb OR (" \
          "issues.auto_merge_evaluated_at IS NOT NULL AND " \
          "issues.auto_merge_blockers IS NOT NULL AND " \
          "projects.owner_reviewer_login IS NOT NULL)",
        hold_label: [ Automation::Strategies::AutoMerge::HOLD_FOR_REVIEW_LABEL ].to_json
      ])
    end

    # A direct indexed count, unlike merge_approval_count: escalation is a
    # column value, not a signal snapshot that needs a Ruby-side check.
    # @spec OPERATOR-INBOX-002C
    def escalated_pr_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, is_pull_request: true, github_state: "open", pr_review_phase: "escalated").count
    end

    # A direct indexed count, unlike merge_approval_count: manual_review is a
    # paid_state value, not a signal snapshot that needs a Ruby-side check.
    # @spec OPERATOR-INBOX-002D
    def manual_review_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, paid_state: "manual_review", github_state: "open").count
    end

    # Mirrors merge_approval_count's shape: a cheap SQL pre-filter narrows to
    # rows that could plausibly carry the intent_conformance blocker before
    # falling back to Ruby for the full Inbox::IntentConformance check.
    # @spec INTENT-CONFORMANCE-006
    def intent_conformance_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      intent_conformance_candidates(project_ids).count { |issue| Inbox::IntentConformance.call(issue).present? }
    end

    def intent_conformance_candidates(project_ids)
      Issue
        .includes(:project)
        .where(
          project_id: project_ids,
          is_pull_request: true,
          github_state: "open",
          pr_review_phase: "ready",
          merge_permission_rejected_at: nil
        )
        .where.not(auto_merge_evaluated_at: nil)
        .where.not(auto_merge_blockers: nil)
        .where.not(projects: { auto_merge_mode: "off" })
    end

    # A direct indexed count: both abandonment producers (runner-retry-cap and
    # push-permission rejection) write the same `runner_retry_abandoned_at`
    # column, so the lane is a single WHERE NOT NULL scan. No paid_state
    # filter — the dashboard's Retry-Limited card deliberately shows both
    # issues and PRs regardless of paid_state, and this lane matches that
    # surface.
    # @spec OPERATOR-INBOX-002E
    def retry_limited_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Issue.where(project_id: project_ids, github_state: "open")
        .where.not(runner_retry_abandoned_at: nil)
        .count
    end

    # @spec CHANGE-INTENT-INBOX-001
    # Change Intent Records follow project membership visibility, independent
    # of the account+owner visibility used by issue-backed inbox lanes.
    def change_intent_draft_count
      ChangeIntentPolicy::Scope.new(user, ChangeIntent).resolve.pending_review.count
    end

    # A direct indexed count sharing the exact lane computation with
    # Inbox::Queue (test_review_pending_issues) so the badge can never
    # disagree with the list, the same sharing partial_closeout_count does.
    # @spec OPERATOR-INBOX-002J
    def test_review_pending_count
      project_ids = visible_project_ids
      return 0 if project_ids.empty?

      Inbox::Queue.test_review_pending_issues(project_ids).count
    end

    # Shares the exact lane computation with Inbox::Queue
    # (Issues::StalledCloseouts) so the badge can never disagree with the
    # list. The SQL prefilter on indexed state columns keeps the scan bounded;
    # the stall population is small by construction (terminal evidence plus no
    # operator hold and no work in flight).
    # @spec PARTIAL-CLOSEOUT-002 @spec PARTIAL-CLOSEOUT-009
    def partial_closeout_count
      projects = Project.where(id: visible_project_ids)
        .includes(account: :tenant_setting, created_by: :user_setting).to_a
      return 0 if projects.empty?

      Issues::StalledCloseouts.call(projects).size
    end

    # Authorized Inbox visibility: account isolation plus per-owner
    # visibility, independent of automatic work-selection eligibility. See
    # `Inbox::Queue#visible_projects` — deliberately does NOT filter on
    # `auto_pick_enabled` or apply `Issues::AutoPickProjectGate` (#4221).
    def visible_project_ids
      @visible_project_ids ||= Project
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          active: true
        )
        .pluck(:id)
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def preload_runner_users(notifications)
      runners = notifications.filter_map(&:subject).select { |subject| subject.is_a?(Runner) }
      ActiveRecord::Associations::Preloader.new(records: runners, associations: :user).call
    end

    def project_for(notification)
      return runner_projects_by_user_id[notification.subject.user_id]&.first if notification.subject.is_a?(Runner)

      notification.resolved_project
    end

    def runner_projects_by_user_id
      @runner_projects_by_user_id ||= Project
        .where(
          account_id: user.account_id,
          created_by_id: visible_owner_ids,
          active: true
        )
        .group_by(&:created_by_id)
    end

    def cache_key
      "inbox/count/#{user.account_id}/#{user.id}/#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)}"
    end
  end
end
