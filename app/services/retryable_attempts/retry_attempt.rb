# frozen_string_literal: true

module RetryableAttempts
  # Shared claim mechanics for a terminal row that may create one successor.
  # Policies own eligibility, identity, admission, and successor construction.
  # @spec AGENT-RETRY-005 AGENT-RETRY-006 AGENT-RETRY-007 AGENT-RETRY-015 AGENT-RETRY-016
  class RetryAttempt
    Result = Data.define(:outcome, :reason, :attempt, :successor) do
      def claimed? = outcome == :claimed
      def scheduled? = outcome == :scheduled
    end

    def initialize(policy:, decision_point:)
      @policy = policy
      @decision_point = decision_point
    end

    def schedule(attempt:, job_class:, delay:)
      assessment = policy.assess(attempt)
      return record_skip(attempt, assessment) unless assessment.eligible?

      job_class.set(wait: delay.call(assessment.attempt)).perform_later(attempt.id, assessment.attempt)
      Result.new(:scheduled, :scheduled, attempt, nil)
    end

    def claim(attempt_id:, retry_number:)
      policy.attempt_class.transaction do
        terminal_attempt = policy.attempt_class.lock.find_by(id: attempt_id)
        next Result.new(:skipped, :missing_attempt, nil, nil) unless terminal_attempt

        assessment = policy.assess(terminal_attempt, retry_number:)
        next record_skip(terminal_attempt, assessment) unless assessment.eligible?

        successor = policy.build_successor!(terminal_attempt, retry_number)
        next record_reason(terminal_attempt, :not_admitted, retry_number) unless successor

        policy.record_claim!(terminal_attempt, successor:, decision_point:, retry_number:)
        Result.new(:claimed, :retry_claimed, terminal_attempt, successor)
      end
    rescue ActiveRecord::RecordNotUnique => error
      raise unless policy.duplicate_claim_conflict?(error)

      terminal_attempt = policy.attempt_class.find_by(id: attempt_id)
      return Result.new(:skipped, :missing_attempt, nil, nil) unless terminal_attempt

      record_reason(terminal_attempt, policy.conflict_reason(error), retry_number)
    end

    private

    attr_reader :policy, :decision_point

    def record_skip(attempt, assessment)
      record_reason(attempt, assessment.reason, assessment.attempt)
    end

    def record_reason(attempt, reason, retry_number)
      policy.record_skip!(attempt, reason:, decision_point:, retry_number:)
      Result.new(:skipped, reason, attempt, nil)
    end
  end
end
