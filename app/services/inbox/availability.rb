# frozen_string_literal: true

module Inbox
  # Which Inbox kinds and projects currently have >=1 matching item, so the
  # filters dialog only offers selections that cannot yield an empty list.
  #
  # Mirrors Inbox::Count's per-kind scopes (cheap SQL counts/signal checks on
  # the same visibility rules every inbox lane uses) rather than
  # Inbox::Queue's full entry build, and caches the per-user matrix behind
  # the same Dashboard::CacheVersion key + short TTL the nav badge uses — so
  # every /inbox render (index, show, open_chat all build availability in
  # load_inbox) pays one cache read instead of re-running all twelve lanes,
  # and the dialog counts stay inside the badge's cache window so the two
  # cannot drift apart mid-window.
  # @spec INBOX-FOUNDATION-010
  class Availability
    CACHE_TTL = 90.seconds

    def self.call(...)
      new(...).call
    end

    def initialize(user:, project: nil, kind: nil)
      @user = user
      @project = project
      @kind = kind.to_s.presence
    end

    def call
      self
    end

    # Kind => count, scoped to the active project filter (if any). Only
    # kinds with a positive count belong in the Type radio group.
    def kind_counts
      @kind_counts ||= Inbox::Queue::KINDS.index_with { |k| count_for_kind(k) }
    end

    def available_kinds
      Inbox::Queue::KINDS.select { |k| kind_counts[k].positive? }
    end

    # project_id => count, scoped to the active kind filter (if any). Only
    # projects with a positive count belong in the Project radio group.
    def project_counts
      @project_counts ||= projects_with_items.index_with { |project_record| count_for_project(project_record) }
        .transform_keys(&:id)
    end

    def available_projects
      projects_with_items.select { |project_record| project_counts[project_record.id].positive? }
    end

    # Unfiltered grand total, independent of the active kind/project filter —
    # used to tell "nothing anywhere" apart from "this combination is empty".
    def total_count
      @total_count ||= matrix.sum { |_kind, per_project| per_project.values.sum }
    end

    # Project ids with >=1 item of `entry_kind`, regardless of the active
    # filters — embedded in the view for client-side narrowing.
    def project_ids_for(entry_kind)
      matrix[entry_kind].keys
    end

    # Kinds with >=1 item in `project_record`, regardless of the active
    # filters — embedded in the view for client-side narrowing.
    def kinds_for(project_record)
      Inbox::Queue::KINDS.select { |k| matrix[k][project_record.id].to_i.positive? }
    end

    private

    attr_reader :user, :project, :kind

    def count_for_kind(entry_kind)
      per_project = matrix[entry_kind]
      project ? per_project[project.id].to_i : per_project.values.sum
    end

    def count_for_project(project_record)
      if kind
        matrix[kind][project_record.id].to_i
      else
        Inbox::Queue::KINDS.sum { |k| matrix[k][project_record.id].to_i }
      end
    end

    def projects_with_items
      @projects_with_items ||= begin
        ids = kind ? matrix[kind].keys : matrix.values.flat_map(&:keys).uniq
        Project.where(id: ids).order(:owner, :repo).to_a
      end
    end

    # One unfiltered per-user matrix feeds every reader (kind_counts,
    # project_counts, total_count, project_ids_for, kinds_for), so it is the
    # single thing worth caching.
    def matrix
      @matrix ||= Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        Inbox::Queue::KINDS.index_with { |k| count_by_project(k) }
      end
    end

    def count_by_project(entry_kind)
      case entry_kind
      when Inbox::Queue::CLARIFYING_QUESTIONS_KIND then needs_input_by_project
      when Inbox::Queue::PLAN_REVIEW_KIND then plan_review_by_project
      when Inbox::Queue::MERGE_APPROVAL_KIND then merge_approval_by_project
      when Inbox::Queue::ACTION_REQUIRED_KIND then action_required_by_project
      when Inbox::Queue::ESCALATED_PR_KIND then escalated_pr_by_project
      when Inbox::Queue::MANUAL_REVIEW_KIND then manual_review_by_project
      when Inbox::Queue::INTENT_CONFORMANCE_KIND then intent_conformance_by_project
      when Inbox::Queue::FEATURE_DECISION_KIND then feature_decision_by_project
      when Inbox::Queue::RETRY_LIMITED_KIND then retry_limited_by_project
      when Inbox::Queue::CHANGE_INTENT_DRAFT_KIND then change_intent_draft_by_project
      when Inbox::Queue::PARTIAL_CLOSEOUT_KIND then partial_closeout_by_project
      when Inbox::Queue::TEST_REVIEW_PENDING_KIND then test_review_pending_by_project
      end
    end

    def needs_input_by_project
      return {} if visible_project_ids.empty?

      Issue.where(project_id: visible_project_ids, paid_state: "needs_input", github_state: "open")
        .select(:id, :project_id, :body, :needs_input_questions)
        .find_each
        .filter_map { |issue| issue.project_id if Inbox::Queue.questions_for(issue).any? }
        .tally
    end

    def plan_review_by_project
      PlanReviewPolicy::Scope.new(user, DecompositionDecision).resolve
        .open_plan_reviews.group(:project_id).count
    end

    def merge_approval_by_project
      return {} if visible_project_ids.empty?

      Inbox::MergeApproval.candidates(visible_project_ids)
        .select { |issue| Inbox::MergeApproval.call(issue).present? }
        .group_by(&:project_id)
        .transform_values(&:count)
    end

    def action_required_by_project
      notifications = NotificationPolicy::Scope.new(user, Notification).resolve.active.blocking
        .includes(:subject).to_a
      Notification.preload_resolved_projects(notifications)
      preload_runner_users(notifications)

      notifications.filter_map { |notification| project_for(notification)&.id }
        .tally
    end

    def escalated_pr_by_project
      return {} if visible_project_ids.empty?

      Issue.where(project_id: visible_project_ids, is_pull_request: true, github_state: "open", pr_review_phase: "escalated")
        .group(:project_id).count
    end

    def manual_review_by_project
      return {} if visible_project_ids.empty?

      Issue.where(project_id: visible_project_ids, paid_state: "manual_review", github_state: "open")
        .group(:project_id).count
    end

    def intent_conformance_by_project
      return {} if visible_project_ids.empty?

      Inbox::IntentConformance.candidates(visible_project_ids)
        .select { |issue| Inbox::IntentConformance.call(issue).present? }
        .group_by(&:project_id)
        .transform_values(&:count)
    end

    def feature_decision_by_project
      FeatureIntentPolicy::Scope.new(user, FeatureIntent).resolve
        .where(status: Inbox::Queue::FEATURE_DECISION_STATUSES)
        .group(:project_id).count
    end

    def retry_limited_by_project
      return {} if visible_project_ids.empty?

      Issue.where(project_id: visible_project_ids, github_state: "open")
        .where.not(runner_retry_abandoned_at: nil)
        .group(:project_id).count
    end

    def change_intent_draft_by_project
      ChangeIntentPolicy::Scope.new(user, ChangeIntent).resolve
        .pending_review.group(:project_id).count
    end

    def partial_closeout_by_project
      return {} if visible_project_ids.empty?

      projects = Project.where(id: visible_project_ids)
        .includes(account: :tenant_setting, created_by: :user_setting).to_a
      Issues::StalledCloseouts.call(projects)
        .map { |pair| pair.issue.project_id }
        .tally
    end

    def test_review_pending_by_project
      return {} if visible_project_ids.empty?

      Inbox::Queue.test_review_pending_issues(visible_project_ids).group(:project_id).count
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
        .where(account_id: user.account_id, created_by_id: visible_owner_ids, active: true)
        .group_by(&:created_by_id)
    end

    def visible_project_ids
      @visible_project_ids ||= Project
        .where(account_id: user.account_id, created_by_id: visible_owner_ids, active: true)
        .pluck(:id)
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def cache_key
      "inbox/availability/#{user.account_id}/#{user.id}/#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)}"
    end
  end
end
