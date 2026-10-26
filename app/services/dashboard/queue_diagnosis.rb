# frozen_string_literal: true

module Dashboard
  # A read-only explanation for an empty queue preview. It deliberately
  # delegates candidate eligibility to EligibilityBreakdown; dashboard reads
  # must not run recovery, GitHub, or semantic assessment work.
  class QueueDiagnosis
    Result = Data.define(:state, :eligible_count, :queued_count, :active_count, :next_action)

    def self.call(...) = new(...).call

    def initialize(user:, queue_preview:)
      @user = user
      @queue_preview = queue_preview
    end

    # @spec QUEUE-HANDOFF-001 QUEUE-HANDOFF-002
    def call
      return Result.new(state: :queued, eligible_count: 0, queued_count: queue_preview.size, active_count: 0, next_action: nil) if queue_preview.any?

      breakdowns = EligibilityBreakdown.call(user: user)
      eligible_count = breakdowns.sum(&:eligible)
      active_count = active_runs_for(breakdowns).count
      state = eligible_count.positive? ? :runnable_unseeded : active_count.positive? ? :healthy_active : :no_waiting_work
      Result.new(state:, eligible_count:, queued_count: 0, active_count:, next_action: next_action_for(state))
    rescue StandardError => error
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error_class: error.class.name)
      Result.new(state: :unknown, eligible_count: nil, queued_count: nil, active_count: nil, next_action: "Refresh this dashboard after the diagnostic service recovers.")
    end

    private

    attr_reader :queue_preview, :user

    def active_runs_for(breakdowns)
      AgentRun.active.where(project_id: breakdowns.map { |breakdown| breakdown.project.id })
    end

    def next_action_for(state)
      return "The periodic eligibility sweep will seed runnable work within 15 minutes." if state == :runnable_unseeded
      return "Monitor the active runs; no additional work is waiting." if state == :healthy_active

      "Inspect Auto-Pick Eligibility for dependency, decision, or policy holds."
    end
  end
end
