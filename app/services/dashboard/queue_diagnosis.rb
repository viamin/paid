# frozen_string_literal: true

module Dashboard
  # Explains an empty scheduler preview from the same candidate data used by
  # EligibilityBreakdown. This is deliberately read-only: rendering a dashboard
  # must never enqueue work, reassess a hold, or contact GitHub.
  class QueueDiagnosis
    Result = Data.define(
      :state, :eligible_count, :queued_count, :active_count, :blocked_count,
      :paused_count, :assessed_at, :recovery_action
    )

    def self.call(...) = new(...).call

    def initialize(user:, breakdowns: nil)
      @user = user
      @breakdowns = breakdowns
    end

    # @spec EAGER-QUEUE-017
    def call
      breakdowns = @breakdowns || EligibilityBreakdown.call(user: user)
      counts = counts_for(breakdowns)
      Result.new(**counts, state: state_for(counts), assessed_at: Time.current, recovery_action: action_for(counts))
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", error_class: error.class.name)
      Result.new(state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil, blocked_count: nil, paused_count: nil,
        assessed_at: nil, recovery_action: "Refresh diagnosis")
    end

    private

    attr_reader :user

    def counts_for(breakdowns)
      project_ids = breakdowns.map { |breakdown| breakdown.project.id }
      {
        eligible_count: breakdowns.sum(&:eligible),
        queued_count: backend_queued_runs(project_ids).count,
        active_count: active_runs(project_ids).count,
        blocked_count: breakdowns.sum { |breakdown| breakdown.other_excluded + breakdown.needs_input + breakdown.manual_review },
        paused_count: paused_projects_count
      }
    end

    def backend_queued_runs(project_ids)
      # This is intentionally the raw backend queue, rather than QueuePreview's
      # priority projection. The latter adds display columns that make SQL COUNT
      # invalid and, more importantly, would conflate a rendering projection
      # with the scheduler's persisted queue contents.
      AgentRun.queued.where(project_id: project_ids)
    end

    def active_runs(project_ids)
      AgentRun.capacity_inflight.where(project_id: project_ids)
    end

    def state_for(counts)
      return :runnable_queued if counts[:queued_count].positive?
      return :eligible_unseeded if counts[:eligible_count].positive?
      return :healthy_active_work if counts[:active_count].positive?
      return :resource_or_policy_pause if counts[:paused_count].positive?
      return :dependency_or_decision_hold if counts[:blocked_count].positive?

      :healthy_idle
    end

    def action_for(counts)
      return "Queue recovery is already scheduled" if counts[:eligible_count].positive?
      return "Resume the paused project to allow admission" if counts[:paused_count].positive?
      return "Review blockers in Inbox" if counts[:blocked_count].positive?

      "Refresh diagnosis"
    end

    def paused_projects_count
      base = Project.where(account_id: user.account_id, created_by_id: visible_owner_ids, auto_pick_enabled: true)
      base.where.not(scheduler_paused_at: nil).or(base.where.not(quality_paused_at: nil)).count
    end

    def visible_owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end
  end
end
