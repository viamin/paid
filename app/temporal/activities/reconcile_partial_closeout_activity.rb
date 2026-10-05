# frozen_string_literal: true

module Activities
  class ReconcilePartialCloseoutActivity < BaseActivity
    activity_name "ReconcilePartialCloseout"

    def execute(input) # @spec NO-OUTPUT-ISSUE-007
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      assessment = persisted_assessment(agent_run)
      PartialCloseouts::Reconcile.call(agent_run: agent_run, assessment: assessment)
      { agent_run_id: agent_run.id, status: agent_run.reload.reconciliation.fetch("status") }
    rescue StandardError => e
      agent_run&.update!(reconciliation: agent_run.reconciliation.merge("status" => "retryable_failure", "error" => e.message))
      raise
    end

    private

    # The assessment is the deterministic input for the deterministic
    # reconciler: persist it on first success and reuse it on retry so gap
    # indices (the replay keys) stay stable across attempts instead of
    # re-invoking the LLM, which may return a different gap set or order.
    def persisted_assessment(agent_run)
      agent_run.reconciliation["assessment"] || Llm::AnalyzePartialCloseout.call(agent_run: agent_run).tap do |result|
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => result))
      end
    end
  end
end
