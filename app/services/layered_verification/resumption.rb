# frozen_string_literal: true

module LayeredVerification
  # Re-admits interrupted audit or repair work only after every mutable
  # admission input is rechecked. It never invokes or replays repair mutations.
  # @spec LAYERED-VERIFY-020
  class Resumption
    Decision = Data.define(:admitted, :reusable_result_ids, :invalidated_result_ids, :limitations, :remaining_budget) do
      def admitted? = admitted
      def replay_repair_mutation? = false
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, user:, dependencies:)
      @agent_run = agent_run
      @user = user
      @dependencies = dependencies
    end

    def call
      AuditAccess.authorize!(user:, project: agent_run.project)
      authorize_repair! if agent_run.goal == "layered_verification_repair"
      raise ArgumentError, "only interrupted layered-verification runs can resume" unless interrupted_run?
      raise ArgumentError, "one or more scoped obligations no longer exist" unless complete_obligation_scope?
      raise ArgumentError, "all obligations require current approval before resumption" unless obligations.all? { |obligation| obligation.approval_state == "approved" }

      remaining_budget = remaining_budget!
      impact = Invalidation.call(obligations:, target_revision: metadata.fetch("target_revision"), dependencies:)
      Decision.new(true, impact.reusable_result_ids, impact.invalidated_result_ids, impact.limitations, remaining_budget)
    end

    private

    attr_reader :agent_run, :dependencies, :user

    def authorize_repair!
      return if ProjectPolicy.new(user, agent_run.project).update?

      raise AuditAccess::UnauthorizedError, "not authorized to resume a layered-verification repair"
    end

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

    def complete_obligation_scope?
      obligations.map { |obligation| obligation.id.to_s }.sort ==
        metadata.fetch("obligation_ids").map(&:to_s).sort
    end

    def metadata = agent_run.external_metadata.fetch("layered_verification")

    def remaining_budget!
      allowance = Audits::Request.resolve_budget!(metadata.fetch("budget")).fetch("max_minutes")
      remaining = allowance - consumed_minutes
      raise Audits::Request::InvalidBudgetError, "no budget remains for resumption" unless remaining.positive?

      { "max_minutes" => remaining }
    end

    def consumed_minutes
      (agent_run.duration.to_i / 60.0).ceil
    end
  end
end
