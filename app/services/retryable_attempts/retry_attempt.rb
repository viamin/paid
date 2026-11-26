# frozen_string_literal: true

module RetryableAttempts
  # Shared claim mechanics for a terminal row that may create one successor.
  # Policies own eligibility, identity, admission, and successor construction.
  # @spec AGENT-RETRY-005 AGENT-RETRY-006 AGENT-RETRY-007 AGENT-RETRY-014 AGENT-RETRY-017 AGENT-RETRY-018
  class RetryAttempt
    Result = Data.define(:outcome, :reason, :attempt, :successor) do
      def claimed? = outcome == :claimed
      def scheduled? = outcome == :scheduled
      def dispatch? = outcome.in?([ :claimed, :existing_active_run ])
    end

    def initialize(policy:, decision_point:)
      @policy = policy
      @decision_point = decision_point
    end

    def schedule(attempt:, job_class:, delay:)
      assessment = policy.assess(attempt)
      return record_skip(attempt, assessment) unless assessment.eligible?

      enqueued_job = job_class.set(wait: delay.call(assessment.attempt)).perform_later(attempt.id, assessment.attempt)
      return record_reason(attempt, :enqueue_declined, assessment.attempt) unless enqueued_job

      policy.record_scheduled!(attempt, decision_point: decision_point, retry_number: assessment.attempt) if policy.respond_to?(:record_scheduled!)
      Result.new(:scheduled, :scheduled, attempt, nil)
    end

    def claim(attempt_id:, retry_number: nil)
      policy.attempt_class.transaction do
        terminal_attempt = policy.attempt_class.lock.find_by(id: attempt_id)
        next Result.new(:skipped, :missing_attempt, nil, nil) unless terminal_attempt

        claim_with_policy_lock(terminal_attempt, retry_number)
      end
    rescue ActiveRecord::RecordNotUnique => error
      raise unless policy.duplicate_claim_conflict?(error)

      terminal_attempt = policy.attempt_class.find_by(id: attempt_id)
      return Result.new(:skipped, :missing_attempt, nil, nil) unless terminal_attempt
      claim_number = retry_number || policy.next_attempt(terminal_attempt)

      if policy.respond_to?(:handle_duplicate_claim!)
        return policy.handle_duplicate_claim!(terminal_attempt, claim_number, error:, decision_point:)
      end

      record_reason(terminal_attempt, policy.conflict_reason(error), claim_number)
    end

    private

    attr_reader :policy, :decision_point

    def record_skip(attempt, assessment)
      if policy.respond_to?(:handle_ineligible!)
        handled = policy.handle_ineligible!(attempt, assessment, decision_point: decision_point)
        return handled if handled
      end

      record_reason(attempt, assessment.reason, assessment.attempt)
    end

    def claim_with_policy_lock(terminal_attempt, retry_number)
      with_policy_lock(terminal_attempt) do
        terminal_attempt.reload
        claim_number = retry_number || policy.next_attempt(terminal_attempt)
        assessment = policy.assess(terminal_attempt, retry_number: claim_number)
        next record_skip(terminal_attempt, assessment) unless assessment.eligible?

        successor = policy.build_successor!(terminal_attempt, assessment.attempt)
        next record_reason(terminal_attempt, :not_admitted, assessment.attempt) unless successor

        policy.record_claim!(terminal_attempt, successor:, decision_point:, retry_number: assessment.attempt)
        Result.new(:claimed, :retry_claimed, terminal_attempt, successor)
      end
    end

    def with_policy_lock(terminal_attempt, &)
      return yield unless policy.respond_to?(:with_claim_lock)

      policy.with_claim_lock(terminal_attempt, &)
    end

    def record_reason(attempt, reason, retry_number)
      policy.record_skip!(attempt, reason:, decision_point:, retry_number:)
      Result.new(:skipped, reason, attempt, nil)
    end
  end
end
