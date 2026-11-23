# frozen_string_literal: true

module LayeredVerification
  # Re-admits interrupted audit or repair work only after every mutable
  # admission input is rechecked. It never invokes or replays repair mutations.
  # @spec LAYERED-VERIFY-020
  class Resumption
    Decision = Data.define(:admitted, :reusable_result_ids, :invalidated_result_ids, :limitations) do
      def admitted? = admitted
      def replay_repair_mutation? = false
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, user:)
      @agent_run = agent_run
      @user = user
    end

    def call
      AuditAccess.authorize!(user:, project: agent_run.project)
      raise ArgumentError, "only interrupted layered-verification runs can resume" unless interrupted_run?
      raise ArgumentError, "all obligations require current approval before resumption" unless obligations.all? { |obligation| obligation.approval_state == "approved" }

      budget!
      impact = Invalidation.call(obligations:, target_revision: metadata.fetch("target_revision"), dependencies: metadata.fetch("dependencies", {}))
      Decision.new(true, impact.reusable_result_ids, impact.invalidated_result_ids, impact.limitations)
    end

    private

    attr_reader :agent_run, :user

    # LAYERED-VERIFY-020 scopes resumption to audit *and* repair runs that were
    # interrupted by cancellation, infrastructure failure, or budget exhaustion
    # (token_budget_exceeded/timeout). TERMINAL_FAILURE_STATUSES enumerates that
    # interruption set, so reuse it rather than an ad hoc status list.
    def interrupted_run?
      agent_run.layered_verification_goal? && agent_run.status.in?(AgentRun::TERMINAL_FAILURE_STATUSES)
    end

    def obligations
      @obligations ||= agent_run.project.layered_verification_obligations.where(id: metadata.fetch("obligation_ids")).to_a
    end

    def metadata = agent_run.external_metadata.fetch("layered_verification")
    def budget! = Audits::Request.resolve_budget!(metadata.fetch("budget"))
  end
end
