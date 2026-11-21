# frozen_string_literal: true

module PartialCloseouts
  # Durable, idempotent recovery state for the post-push source-closure gate.
  # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045 PARTIAL-CLOSEOUT-059 PARTIAL-CLOSEOUT-060
  class SourceClosureRecovery
    KEY = "source_closure_recovery"
    RETRY_DELAY = 10.minutes
    MAX_AUTOMATIC_RECOVERY_ATTEMPTS = 3
    MAX_OPERATOR_RECOVERY_ATTEMPTS = 1

    def self.park!(...) = new(...).park!
    def self.claim!(...) = new(...).claim!
    def self.release_claim!(...) = new(...).release_claim!
    def self.record_assessment_request!(...) = new(...).record_assessment_request!

    def initialize(agent_run:, category: nil, attempts: nil, now: Time.current, expected_recovery_attempt: nil,
      operator_authorized: false)
      @agent_run = agent_run
      @category = category
      @attempts = attempts
      @now = now
      @expected_recovery_attempt = expected_recovery_attempt
      @operator_authorized = operator_authorized
    end

    def park!
      agent_run.with_lock do
        agent_run.reload
        recovery = state.merge(
          "failed_step" => "assess_source_closure",
          "branch_name" => agent_run.branch_name,
          "commit_sha" => agent_run.result_commit_sha,
          "attempts" => attempts,
          "failure_category" => category,
          "claimed_at" => nil,
          "next_retry_at" => next_retry_at
        )
        agent_run.update!(status: "waiting_recovery", reconciliation: agent_run.reconciliation.merge(KEY => recovery)) unless agent_run.finished?
      end
    end

    def claim!
      agent_run.with_lock do
        agent_run.reload
        return false unless agent_run.waiting_recovery? && claim_available?
        return false if @expected_recovery_attempt && state.fetch("recovery_attempt", 0).to_i != @expected_recovery_attempt
        return stop! unless budget_available?

        agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => state.merge(
          "claimed_at" => now.iso8601,
          "recovery_attempt" => state.fetch("recovery_attempt", 0).to_i + 1,
          attempt_key => state.fetch(attempt_key, 0).to_i + 1,
          "stop_reason" => nil,
          "next_retry_at" => nil
        )))
        true
      end
    end

    def record_assessment_request!
      agent_run.with_lock do
        agent_run.reload
        return false if state.empty?

        agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => state.merge(
          "assessment_request_count" => state.fetch("assessment_request_count", 0).to_i + 1,
          "last_assessment_request_at" => now.iso8601
        )))
        true
      end
    end

    def release_claim!
      agent_run.with_lock do
        agent_run.reload
        return false unless state["recovery_attempt"].to_i == @attempts.to_i

        agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => state.merge("claimed_at" => nil)))
        true
      end
    end

    private

    attr_reader :agent_run, :category, :now

    def state = agent_run.reconciliation.to_h.fetch(KEY, {})
    def attempts = @attempts || state.fetch("attempts", 0).to_i + 1

    def attempt_key = @operator_authorized ? "operator_recovery_attempt" : "automatic_recovery_attempt"

    def maximum_attempts = @operator_authorized ? MAX_OPERATOR_RECOVERY_ATTEMPTS : MAX_AUTOMATIC_RECOVERY_ATTEMPTS

    def budget_available? = state.fetch(attempt_key, 0).to_i < maximum_attempts

    def next_retry_at
      return nil if state.fetch("automatic_recovery_attempt", 0).to_i >= MAX_AUTOMATIC_RECOVERY_ATTEMPTS

      (now + RETRY_DELAY).iso8601
    end

    def stop!
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => state.merge(
        "claimed_at" => nil,
        "next_retry_at" => nil,
        "stop_reason" => @operator_authorized ? "operator_recovery_budget_exhausted" : "automatic_recovery_budget_exhausted"
      )))
      false
    end

    def claim_available?
      state["claimed_at"].blank? || Time.zone.parse(state.fetch("claimed_at")) <= now - RETRY_DELAY
    rescue ArgumentError
      true
    end
  end
end
