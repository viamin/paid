# frozen_string_literal: true

module Dashboard
  # Explains the difference between candidate work and scheduler work. This is
  # deliberately read-only: dashboard requests must not trigger recovery.
  class QueueDiagnosis
    Result = Struct.new(
      :state, :open_count, :eligible_count, :queued_count, :active_count,
      :unseeded_issue_ids, :error, keyword_init: true
    ) do
      def refresh_recommended?
        state == :unknown
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(user:)
      @user = user
    end

    # @spec QUEUE-HANDOFF-001 QUEUE-HANDOFF-002
    def call
      breakdowns = EligibilityBreakdown.call(user:)
      project_ids = breakdowns.map { |breakdown| breakdown.project.id }
      return empty_result if project_ids.empty?

      eligible_issue_ids = eligible_issue_ids_for(breakdowns)
      queued_count, active_count, seeded_issue_ids = scheduler_counts(project_ids)
      unseeded_issue_ids = eligible_issue_ids - seeded_issue_ids

      Result.new(
        state: state_for(breakdowns, unseeded_issue_ids, queued_count, active_count),
        open_count: breakdowns.sum(&:total_open),
        eligible_count: eligible_issue_ids.size,
        queued_count:,
        active_count:,
        unseeded_issue_ids:
      )
    rescue ActiveRecord::ActiveRecordError, RedisClient::Error => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error: error.message)
      Result.new(state: :unknown, open_count: nil, eligible_count: nil, queued_count: nil,
        active_count: nil, unseeded_issue_ids: [], error: error.class.name)
    end

    private

    attr_reader :user

    def empty_result
      Result.new(state: :empty, open_count: 0, eligible_count: 0, queued_count: 0,
        active_count: 0, unseeded_issue_ids: [])
    end

    def eligible_issue_ids_for(breakdowns)
      resolver = Runners::TierFeasibility.new
      breakdowns.flat_map do |breakdown|
        Automation::Strategies::AutoPick::DefaultCandidateSource
          .eligible_scope(breakdown.project, tier_feasibility: resolver)
          .order(:id)
          .limit(50)
          .pluck(:id)
      end
    end

    def scheduler_counts(project_ids)
      runs = AgentRun.where(project_id: project_ids)
      queued_count = runs.queued.count
      active_count = runs.capacity_inflight.count
      seeded_issue_ids = runs.where(auto_pick: true, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES)
        .where.not(issue_id: nil).distinct.pluck(:issue_id)
      [ queued_count, active_count, seeded_issue_ids ]
    end

    def state_for(breakdowns, unseeded_issue_ids, queued_count, active_count)
      return :unseeded_work if unseeded_issue_ids.any?
      return :active_work if active_count.positive?
      return :scheduled_work if queued_count.positive?
      return :held_work if breakdowns.sum(&:total_open).positive?

      :empty
    end
  end
end
