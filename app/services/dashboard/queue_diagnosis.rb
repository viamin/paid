# frozen_string_literal: true

module Dashboard
  # A read-only interpretation of the candidate and scheduler facts used by
  # the two dashboard frames. Recovery belongs to event handlers and the
  # bounded eligibility sweep; rendering must never enqueue work or call a
  # semantic assessor.
  class QueueDiagnosis
    Result = Struct.new(:state, :eligible, :queued, :running, :issues, :blockers, :error, keyword_init: true)

    # @spec QUEUE-HANDOFF-001 QUEUE-HANDOFF-002
    def self.call(breakdowns:)
      new(breakdowns:).call
    end

    # @spec QUEUE-HANDOFF-003
    def self.unavailable(error:)
      Result.new(state: :unknown, eligible: nil, queued: nil, running: nil, issues: [], blockers: [], error:)
    end

    def initialize(breakdowns:)
      @breakdowns = breakdowns
    end

    def call
      Result.new(
        state: state,
        eligible: eligible,
        queued: queued,
        running: running,
        issues: breakdowns.flat_map { |breakdown| candidate_issue_ids(breakdown) },
        blockers: blockers,
        error: nil
      )
    end

    private

    attr_reader :breakdowns

    def state
      return :runnable_unseeded if eligible.positive? && queued.zero?
      return :healthy_active_work if running.positive? && eligible.zero? && queued.zero?
      return :blocked if blockers.any?
      :paused
    end

    def eligible = breakdowns.sum(&:eligible)
    def queued = breakdowns.sum { |breakdown| breakdown.queued.to_i }
    def running = breakdowns.sum { |breakdown| breakdown.running.to_i }
    def blockers = breakdowns.flat_map { |breakdown| Array(breakdown.blockers) }

    def candidate_issue_ids(breakdown)
      return [] unless breakdown.eligible.positive?

      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(breakdown.project).limit(20).ids
    end
  end
end
