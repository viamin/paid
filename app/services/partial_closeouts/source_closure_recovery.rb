# frozen_string_literal: true

module PartialCloseouts
  # Durable, idempotent recovery state for the post-push source-closure gate.
  # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
  class SourceClosureRecovery
    KEY = "source_closure_recovery"
    RETRY_DELAY = 10.minutes

    def self.park!(...) = new(...).park!
    def self.claim!(...) = new(...).claim!

    def initialize(agent_run:, category: nil, attempts: nil, now: Time.current)
      @agent_run = agent_run
      @category = category
      @attempts = attempts
      @now = now
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
          "next_retry_at" => (now + RETRY_DELAY).iso8601,
          "claimed_at" => nil
        )
        agent_run.update!(status: "waiting_recovery", reconciliation: agent_run.reconciliation.merge(KEY => recovery)) unless agent_run.finished?
      end
    end

    def claim!
      agent_run.with_lock do
        agent_run.reload
        return false unless agent_run.waiting_recovery? && state["claimed_at"].blank?

        agent_run.update!(reconciliation: agent_run.reconciliation.merge(KEY => state.merge(
          "claimed_at" => now.iso8601,
          "recovery_attempt" => state.fetch("recovery_attempt", 0).to_i + 1
        )))
        true
      end
    end

    private

    attr_reader :agent_run, :category, :now

    def state = agent_run.reconciliation.to_h.fetch(KEY, {})
    def attempts = @attempts || state.fetch("attempts", 0).to_i + 1
  end
end
