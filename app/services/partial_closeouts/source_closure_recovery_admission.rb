# frozen_string_literal: true

module PartialCloseouts
  # Rechecks the current authority to spend an automatic source-closure attempt.
  # @spec PARTIAL-CLOSEOUT-061
  class SourceClosureRecoveryAdmission
    Result = Data.define(:allowed, :reason)

    def self.call(...) = new(...).call

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return denied("automatic_recovery_authorization_withdrawn") unless project.auto_pick_enabled?
      return denied("automatic_recovery_paused") if paused?
      return denied("automatic_recovery_authorization_withdrawn") unless Issues::AutoPickProjectGate.call(project)
      return denied("automatic_recovery_source_untrusted") unless issue&.trusted?
      return denied("automatic_recovery_policy_withdrawn") if withdrawn_phase_policy
      return denied("automatic_recovery_budget_exhausted") unless budget.fetch(:allowed)

      Result.new(allowed: true, reason: nil)
    end

    private

    attr_reader :agent_run

    def project = @project ||= agent_run.project.reload
    def issue = @issue ||= agent_run.issue&.reload
    def budget = @budget ||= CostBudgets::Check.call(project, agent_run:)

    def withdrawn_phase_policy = AgentRuns::RecheckIssueEligibility.withdrawn_phase_policy(agent_run)

    def paused?
      project.paused? || project.scheduler_paused? || project.quality_paused? ||
        project.account.scheduler_paused? || issue&.paused?
    end

    def denied(reason) = Result.new(allowed: false, reason:)
  end
end
