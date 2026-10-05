# frozen_string_literal: true

module Activities
  class ReconcilePartialCloseoutActivity < BaseActivity
    activity_name "ReconcilePartialCloseout"

    def execute(input) # @spec NO-OUTPUT-ISSUE-007
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      assessment = Llm::AnalyzePartialCloseout.call(agent_run: agent_run)
      PartialCloseouts::Reconcile.call(agent_run: agent_run, assessment: assessment)
      { agent_run_id: agent_run.id, status: agent_run.reload.reconciliation.fetch("status") }
    rescue StandardError => e
      agent_run&.update!(reconciliation: agent_run.reconciliation.merge("status" => "retryable_failure", "error" => e.message))
      raise
    end
  end
end
