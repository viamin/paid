# frozen_string_literal: true

module Activities
  # Refreshes persisted closeout evidence for an admitted report-only audit.
  # It intentionally does not use AnalyzeIssueActivity: that activity's
  # readiness verdict creates implementation follow-up work.
  # @spec PARTIAL-CLOSEOUT-027
  class RunAcceptanceAuditActivity < BaseActivity
    activity_name "RunAcceptanceAudit"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "run_acceptance_audit",
        phase_group: "agent", agent_run: agent_run) do
        agent_run.start!
        assessment = Llm::AnalyzePartialCloseout.call(agent_run: agent_run)
        snapshot = PartialCloseouts::Assessment.snapshot(agent_run, assessment)
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => snapshot))
        PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: snapshot)
        PartialCloseouts::Reconcile.call(agent_run:, assessment: snapshot)
        agent_run.complete!
        ProcessRunQueueJob.perform_later
        { agent_run_id: agent_run.id, assessment_recorded: true }
      end
    end
  end
end
