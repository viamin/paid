# frozen_string_literal: true

module Dashboard
  # Explains an empty queue from the same eligibility and scheduler facts that
  # control work admission. This query is deliberately read-only: event hooks
  # and AutoPickEligibilitySweepJob own recovery, and semantic closeout review
  # stays in the existing agent-harness path.
  class QueueDiagnosis
    Result = Struct.new(
      :state, :eligible_count, :queued_count, :running_count, :held_count,
      :paused_count, :error,
      keyword_init: true
    )

    def self.call(...)
      new(...).call
    end

    def initialize(user:, breakdowns: nil)
      @user = user
      @breakdowns = breakdowns
    end

    # @spec QUEUE-HANDOFF-001 QUEUE-HANDOFF-002
    def call
      build_result
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "dashboard.queue_diagnosis_unavailable",
        account_id: user.account_id,
        user_id: user.id,
        error_class: e.class.name
      )
      Result.new(state: :unavailable, error: "Queue diagnosis is temporarily unavailable.")
    end

    private

    attr_reader :breakdowns, :user

    def build_result
      breakdown_rows = breakdowns || EligibilityBreakdown.call(user: user)
      project_ids = visible_project_ids
      queued_count, running_count = run_counts(project_ids)
      eligible_count = breakdown_rows.sum(&:eligible)
      held_count = breakdown_rows.sum { |row| row.total_open - row.eligible }
      paused_count = paused_projects(project_ids).count

      Result.new(
        state: state_for(queued_count:, running_count:, eligible_count:, held_count:, paused_count:),
        eligible_count:, queued_count:, running_count:, held_count:, paused_count:
      )
    end

    def state_for(queued_count:, running_count:, eligible_count:, held_count:, paused_count:)
      return :queued_work if queued_count.positive?
      return :active_work if running_count.positive?
      return :runnable_unseeded if eligible_count.positive?
      return :paused if paused_count.positive?
      return :held if held_count.positive?

      :empty
    end

    def visible_project_ids
      scope = Project.where(account_id: user.account_id, created_by_id: visible_owner_ids)
      scope.ids
    end

    def visible_owner_ids
      owner_ids = [ user.id ]
      owner_ids << nil if AgentRun.orphaned_project_owner?(user)
      owner_ids
    end

    def run_counts(project_ids)
      return [ 0, 0 ] if project_ids.empty?

      counts = AgentRun.where(project_id: project_ids, status: %w[queued running]).group(:status).count
      [ counts.fetch("queued", 0), counts.fetch("running", 0) ]
    end

    def paused_projects(project_ids)
      Project.where(id: project_ids, auto_pick_enabled: true)
        .where("projects.scheduler_paused_at IS NOT NULL OR projects.quality_paused_at IS NOT NULL")
    end
  end
end
