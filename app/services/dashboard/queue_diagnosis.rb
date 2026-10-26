# frozen_string_literal: true

module Dashboard
  # Explains an empty rendered queue without becoming another eligibility path.
  class QueueDiagnosis
    Result = Struct.new(:state, :eligible_count, :queued_count, :active_count, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(user:, breakdowns: nil)
      @user = user
      @breakdowns = breakdowns
    end

    # @spec DASHBOARD-QUEUE-DIAGNOSIS-001
    def call
      breakdowns = @breakdowns || EligibilityBreakdown.call(user: user)
      project_ids = breakdowns.map { |breakdown| breakdown.project.id }
      counts = AgentRun.where(project_id: project_ids).group(:status).count
      eligible_count = breakdowns.sum(&:eligible)
      queued_count = counts.fetch("queued", 0)
      active_count = AgentRun::ACTIVE_STATUSES.sum { |status| counts.fetch(status, 0) }

      Result.new(state: state_for(eligible_count, queued_count, active_count, breakdowns), eligible_count:, queued_count:, active_count:)
    rescue ActiveRecord::ActiveRecordError
      Result.new(state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil)
    end

    private

    attr_reader :user

    def state_for(eligible_count, queued_count, active_count, breakdowns)
      return :active_work if active_count.positive? && queued_count.zero?
      return :runnable_unseeded if eligible_count.positive? && queued_count.zero?
      return :dependency_or_decision_hold if eligible_count.zero? && held_count(breakdowns).positive?

      :no_waiting_work
    end

    def held_count(breakdowns)
      breakdowns.sum { |breakdown| breakdown.needs_input + breakdown.manual_review + breakdown.other_excluded }
    end
  end
end
