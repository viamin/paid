# frozen_string_literal: true

module Retries
  # Shared scheduling and atomic-claim mechanics for retry policies. Policies
  # retain their own eligibility rules, admission rechecks, successor shape,
  # supersede marking, and decision-record wiring; the attempt record is
  # whatever the policy owns (an AgentRun, an AppleVerificationAttempt, ...)
  # and is never assumed to be an AgentRun.
  #
  # Policy protocol (duck-typed):
  # - assess(source, attempt_number: next_attempt_number(source)) — budget,
  #   failure-class, and state-drift eligibility returning Retries::Assessment
  # - next_attempt_number(source) — the next 1-indexed attempt number
  # - maximum_attempts — the bounded attempt counter's cap
  # - claim_transaction { ... } — the claim's single transaction boundary
  # - lock_source(id) / find_source(id) — locked claim-time load and
  #   rescue-path load of the source record
  # - admission_reason(source) — use-case admission recheck under the claim
  #   lock; nil when admissible, else a Symbol reason
  # - build_successor!(source, attempt_number) — successor construction
  # - duplicate_claim_conflict?(error) / duplicate_claim_conflict_reason(error) —
  #   recognize the policy's own unique-index races and name their no-op reason
  # - record_claim!(source, successor:, decision_point:, signals:) — applied
  #   durable decision, plus model-specific supersede marking
  # - record_skip!(source, reason:, decision_point:, signals:) — noop durable
  #   decision for a refused, skipped, or exhausted claim
  # @spec AGENT-RETRY-004 AGENT-RETRY-005 AGENT-RETRY-006 AGENT-RETRY-007 AGENT-RETRY-015
  class Attempt
    Result = Data.define(:outcome, :reason, :source, :successor) do
      def claimed? = outcome == :claimed
      def scheduled? = outcome == :scheduled
      def skipped? = outcome == :skipped
    end

    def initialize(policy:, decision_point:)
      @policy = policy
      @decision_point = decision_point
    end

    def schedule(source:, job_class:, delay:)
      assessment = policy.assess(source)
      return record_skip(source, assessment.reason, assessment.attempt_number) unless assessment.eligible?

      job_class.set(wait: delay.call(assessment.attempt_number)).perform_later(source.id, assessment.attempt_number)
      Result.new(:scheduled, :scheduled, source, nil)
    end

    def claim(source_id:, attempt_number: nil)
      policy.claim_transaction do
        source = policy.lock_source(source_id)
        next Result.new(:skipped, :missing_source, nil, nil) unless source

        assessment = policy.assess(source, attempt_number: attempt_number || policy.next_attempt_number(source))
        next record_skip(source, assessment.reason, assessment.attempt_number) unless assessment.eligible?

        admission_reason = policy.admission_reason(source)
        next record_skip(source, admission_reason, assessment.attempt_number) if admission_reason

        successor = policy.build_successor!(source, assessment.attempt_number)
        policy.record_claim!(source, successor: successor, decision_point: decision_point, signals: retry_signals(assessment.attempt_number))
        Result.new(:claimed, :retry_claimed, source, successor)
      end
    rescue ActiveRecord::RecordNotUnique => error
      raise unless policy.duplicate_claim_conflict?(error)

      source = policy.find_source(source_id)
      reason = policy.duplicate_claim_conflict_reason(error)
      source ? record_skip(source, reason, attempt_number || policy.next_attempt_number(source)) : Result.new(:skipped, :missing_source, nil, nil)
    end

    private

    attr_reader :policy, :decision_point

    def record_skip(source, reason, attempt_number)
      policy.record_skip!(source, reason: reason, decision_point: decision_point, signals: retry_signals(attempt_number))
      Result.new(:skipped, reason, source, nil)
    end

    def retry_signals(attempt_number)
      { attempt: attempt_number, max_attempts: policy.maximum_attempts }
    end
  end
end
