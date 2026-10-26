# frozen_string_literal: true

module Dashboard
  # Explains an empty queue from the same candidate and scheduler facts used by
  # the queue itself. This query deliberately has no recovery side effects.
  # @spec QUEUE-DIAGNOSIS-001 QUEUE-DIAGNOSIS-002 QUEUE-DIAGNOSIS-003 QUEUE-DIAGNOSIS-004
  class QueueDiagnosis
    MAX_BLOCKERS = 25

    Blocker = Data.define(:issue, :reasons)
    Result = Data.define(
      :state, :eligible_count, :queued_count, :active_count, :blockers,
      :refreshed_at, :error
    ) do
      def unknown? = state == :unknown
      def refresh_needed? = state.in?([ :stale_dashboard, :unknown ])
    end

    def self.call(...) = new(...).call

    def initialize(user:, rendered_queue_count: nil)
      @user = user
      @rendered_queue_count = rendered_queue_count
    end

    def call
      projects = visible_projects
      breakdowns = EligibilityBreakdown.call(user: user)
      eligible_count = breakdowns.sum(&:eligible)
      queued_count = scheduler_queued_count(projects)
      active_runs = scheduler_active_runs(projects)
      blockers = blocker_records(projects, active_runs)

      Result.new(
        state: state_for(projects:, eligible_count:, queued_count:, active_count: active_runs.size, blockers:),
        eligible_count:, queued_count:, active_count: active_runs.size, blockers:,
        refreshed_at: Time.current, error: nil
      )
    rescue ActiveRecord::ActiveRecordError, RedisClient::Error => error
      Rails.logger.warn(
        message: "dashboard.queue_diagnosis_unavailable",
        account_id: user.account_id,
        user_id: user.id,
        error_class: error.class.name,
        error_message: error.message
      )
      unavailable(error)
    end

    private

    attr_reader :user, :rendered_queue_count

    def visible_projects
      scope = Project.where(account_id: user.account_id, created_by_id: visible_owner_ids, auto_pick_enabled: true, active: true)
      scope.to_a
    end

    def visible_owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end

    def scheduler_queued_count(projects)
      return 0 if projects.empty?

      AgentRun.schedulable_queued_with_priority.unscope(:select, :order)
        .where(project_id: projects.map(&:id)).count
    end

    def scheduler_active_runs(projects)
      return [] if projects.empty?

      AgentRun.active.where(project_id: projects.map(&:id)).where.not(issue_id: nil).to_a
    end

    def blocker_records(projects, active_runs)
      active_issue_ids = active_runs.map(&:issue_id).to_set
      projects.flat_map { |project| blockers_for(project, active_issue_ids) }.first(MAX_BLOCKERS)
    end

    def blockers_for(project, active_issue_ids)
      return [] if project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused?

      eligible_ids = Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).pluck(:id).to_set
      project.issues.where(github_state: "open", is_pull_request: false)
        .includes(issue_dependencies: :depends_on_issue)
        .where.not(id: eligible_ids.to_a)
        .limit(MAX_BLOCKERS)
        .filter_map do |issue|
          reasons = reasons_for(issue, project, active_issue_ids)
          Blocker.new(issue:, reasons:) if reasons.any?
        end
    end

    def reasons_for(issue, project, active_issue_ids)
      reasons = []
      reasons << :active_work if active_issue_ids.include?(issue.id)
      reasons << :dependency if issue.issue_dependencies.any? { |dependency| dependency.depends_on_issue&.github_state == "open" }
      reasons << :needs_input if (issue.labels.map(&:downcase) & project.needs_input_labels.map(&:downcase)).any?
      reasons << :skip_label if (issue.labels.map(&:downcase) & project.effective_auto_pick_skip_labels.map(&:downcase)).any?
      reasons
    end

    def state_for(projects:, eligible_count:, queued_count:, active_count:, blockers:)
      return :stale_dashboard if queued_count.positive? && rendered_queue_count.to_i.zero?
      return :backend_queue_nonempty if queued_count.positive?
      return :resource_policy_paused if projects.any? { |project| project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused? }
      return :runnable_unseeded if eligible_count.positive?
      return :healthy_active_work if active_count.positive?
      return :genuine_holds if blockers.any?

      :healthy_no_waiting_work
    end

    def unavailable(error)
      Result.new(
        state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil,
        blockers: [], refreshed_at: Time.current, error: error.class.name
      )
    end
  end
end
