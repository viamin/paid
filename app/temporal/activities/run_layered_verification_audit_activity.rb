# frozen_string_literal: true

module Activities
  # Records an audit-only, bounded coverage report. The coordinator deliberately
  # does not provision a coding workspace or enqueue a repair.
  class RunLayeredVerificationAuditActivity < BaseActivity
    # @spec LAYERED-VERIFY-021 @spec LAYERED-VERIFY-024
    activity_name "RunLayeredVerificationAudit"

    def execute(input)
      run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: run.id, phase_key: "run_layered_verification_audit", phase_group: "verification", agent_run: run) do
        run.start!
        snapshot = run.reconciliation.fetch("layered_verification_audit")
        obligations = run.project.layered_verification_obligations.where(external_identity: snapshot.fetch("scope"))
        results = obligations.map { |obligation| record_unresolved_plan(run, obligation, snapshot) }
        run.update!(reconciliation: run.reconciliation.merge("layered_verification_audit" => snapshot.merge("progress" => "completed", "coverage" => results)))
        run.complete!
        ProcessRunQueueJob.perform_later
        { agent_run_id: run.id, coverage_count: results.size }
      end
    end

    private

    def record_unresolved_plan(run, obligation, snapshot)
      limitation = "No executable check was selected: the bounded audit has no declared supported command or correspondence claim."
      result = obligation.check_results.create!(agent_run: run, producer: "verification_planning", execution_state: "non_applicable",
        obligation_coverage: "unresolved", input_revision: { "external_revision" => snapshot.fetch("target_revision") },
        evidence_summary: { "scope" => snapshot.fetch("scope"), "source_references" => snapshot.fetch("source_references") },
        agent_reported: {}, recorder_verified: {}, cost: { "budget" => snapshot.fetch("budget") }, limitations: limitation)
      { "obligation_id" => obligation.id, "approval_state" => obligation.approval_state, "coverage" => result.obligation_coverage, "check_result_id" => result.id, "limitations" => limitation }
    end
  end
end
