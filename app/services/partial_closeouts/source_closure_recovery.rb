# frozen_string_literal: true

module PartialCloseouts
  # Durable, idempotent recovery state for the post-push source-closure gate.
  # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045 PARTIAL-CLOSEOUT-061 PARTIAL-CLOSEOUT-060
  class SourceClosureRecovery
    AUTOMATIC_CLAIM = Object.new.freeze
    KEY = "source_closure_recovery"
    RETRY_DELAY = 10.minutes
    MAX_AUTOMATIC_RECOVERY_ATTEMPTS = 3
    MAX_OPERATOR_RECOVERY_ATTEMPTS = 1

    def self.park!(...) = new(...).park!
    def self.claim!(...) = new(...).claim!
    def self.release_claim!(...) = new(...).release_claim!
    def self.record_assessment_request!(...) = new(...).record_assessment_request!

    def initialize(agent_run:, category: nil, attempts: nil, now: Time.current, expected_recovery_attempt: nil,
      operator: AUTOMATIC_CLAIM)
      @agent_run = agent_run
      @category = category
      @attempts = attempts
      @now = now
      @expected_recovery_attempt = expected_recovery_attempt
      @operator = operator
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
          "next_retry_at" => next_retry_at,
          "stop_reason" => stop_reason_for_parking
        )
        agent_run.update!(status: "waiting_recovery", reconciliation: agent_run.reconciliation.merge(KEY => recovery)) unless agent_run.finished?
      end
    end

    def claim!
      agent_run.with_lock do
        agent_run.reload
        return false unless agent_run.waiting_recovery? && claim_available?
        return false if @expected_recovery_attempt && state.fetch("recovery_attempt", 0).to_i != @expected_recovery_attempt
        return stop!(budget_exhausted_reason) unless budget_available?

        admission = SourceClosureRecoveryAdmission.call(agent_run:, operator: @operator, operator_claim: operator_claim?)
        return stop!(admission.reason) unless admission.allowed

        agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => state.merge(
          "claimed_at" => now.iso8601,
          "recovery_attempt" => state.fetch("recovery_attempt", 0).to_i + 1,
          attempt_key => attempts_for_claim + 1,
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

    def operator_claim? = @operator != AUTOMATIC_CLAIM

    def attempt_key = operator_claim? ? "operator_recovery_attempt" : "automatic_recovery_attempt"

    def maximum_attempts = operator_claim? ? MAX_OPERATOR_RECOVERY_ATTEMPTS : MAX_AUTOMATIC_RECOVERY_ATTEMPTS

    def budget_available? = attempts_for_claim < maximum_attempts

    def attempts_for_claim
      return state.fetch(attempt_key, 0).to_i if operator_claim?

      automatic_attempts
    end

    def automatic_attempts
      [ state.fetch("automatic_recovery_attempt", 0).to_i, state.fetch("recovery_attempt", 0).to_i ].max
    end

    def next_retry_at
      return nil if automatic_attempts >= MAX_AUTOMATIC_RECOVERY_ATTEMPTS

      (now + RETRY_DELAY).iso8601
    end

    def stop!(reason)
      recovery = state.merge(
        "claimed_at" => nil,
        "next_retry_at" => nil,
        "stop_reason" => reason
      )
      recovery["automatic_recovery_attempt"] = automatic_attempts unless operator_claim?
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => recovery))
      false
    end

    def budget_exhausted_reason
      operator_claim? ? "operator_recovery_budget_exhausted" : "automatic_recovery_budget_exhausted"
    end

    def stop_reason_for_parking
      return "automatic_recovery_budget_exhausted" if automatic_attempts >= MAX_AUTOMATIC_RECOVERY_ATTEMPTS

      state["stop_reason"]
    end

    def claim_available?
      state["claimed_at"].blank? || Time.zone.parse(state.fetch("claimed_at")) <= now - RETRY_DELAY
    rescue ArgumentError
      true
    end
  end
end
