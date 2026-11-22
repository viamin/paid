# frozen_string_literal: true

module PartialCloseouts
  # Rechecks the current authority to spend a source-closure recovery attempt.
  # @spec PARTIAL-CLOSEOUT-061 PARTIAL-CLOSEOUT-060
  class SourceClosureRecoveryAdmission
    Result = Data.define(:allowed, :reason)

    def self.call(...) = new(...).call

    def initialize(agent_run:, operator: nil, operator_claim: false)
      @agent_run = agent_run
      @operator = operator
      @operator_claim = operator_claim
    end

    def call
      return denied("#{reason_prefix}_recovery_authorization_withdrawn") unless initially_authorized?
      return denied("#{reason_prefix}_recovery_paused") if paused?
      return denied("automatic_recovery_authorization_withdrawn") unless automatic_gate_open?
      return denied("#{reason_prefix}_recovery_source_untrusted") unless issue&.trusted?
      return denied("automatic_recovery_policy_withdrawn") if automatic_claim? && withdrawn_phase_policy
      return denied(cost_budget_reason) unless budget.fetch(:allowed)

      Result.new(allowed: true, reason: nil)
    end

    private

    attr_reader :agent_run, :operator

    def project = @project ||= agent_run.project.reload
    def issue = @issue ||= agent_run.issue&.reload
    def budget = @budget ||= CostBudgets::Check.call(project, agent_run:)

    def withdrawn_phase_policy = AgentRuns::RecheckIssueEligibility.withdrawn_phase_policy(agent_run)

    def automatic_claim? = !@operator_claim

    def initially_authorized?
      return AgentRunPolicy.new(operator, agent_run).retry? unless automatic_claim?

      project.auto_pick_enabled?
    end

    def automatic_gate_open? = !automatic_claim? || Issues::AutoPickProjectGate.call(project)

    def reason_prefix = automatic_claim? ? "automatic" : "operator"

    def cost_budget_reason
      automatic_claim? ? "automatic_recovery_budget_exhausted" : "operator_recovery_cost_budget_exhausted"
    end

    def paused?
      project.paused? || project.scheduler_paused? || project.quality_paused? ||
        project.account.scheduler_paused? || issue&.paused?
    end

    def denied(reason) = Result.new(allowed: false, reason:)
  end
end
