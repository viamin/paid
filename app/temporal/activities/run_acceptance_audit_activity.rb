# frozen_string_literal: true

module Activities
  # Refreshes persisted closeout evidence for an admitted report-only audit.
  # It intentionally does not use AnalyzeIssueActivity: that activity's
  # readiness verdict creates implementation follow-up work.
  # @spec PARTIAL-CLOSEOUT-027
  class RunAcceptanceAuditActivity < BaseActivity
    activity_name "RunAcceptanceAudit"
    MAX_ASSESSMENT_TIMEOUT = 300

    def execute(input) # @spec PARTIAL-CLOSEOUT-047
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "run_acceptance_audit",
        phase_group: "agent", agent_run: agent_run) do
        agent_run.start!
        fallbacks = fallback_runner_identifiers(agent_run)
        assessment = assess(agent_run, fallbacks)
        snapshot = PartialCloseouts::Assessment.snapshot(agent_run, assessment)
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => snapshot))
        PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: snapshot)
        PartialCloseouts::Reconcile.call(agent_run:, assessment: snapshot)
        agent_run.complete!
        ProcessRunQueueJob.perform_later
        { agent_run_id: agent_run.id, assessment_recorded: true }
      end
    end

    private

    def assess(agent_run, fallbacks)
      Llm::AnalyzePartialCloseout.call(agent_run: agent_run,
        fallback_runner_identifiers: fallbacks,
        timeout: [ Llm::AnalyzePartialCloseout::TIMEOUT * (fallbacks.size + 1), MAX_ASSESSMENT_TIMEOUT ].min)
    rescue Llm::AnalyzePartialCloseout::AssessmentFailure => error
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(
        "acceptance_audit_failure" => { "category" => error.diagnostic.fetch(:category), "at" => Time.current.iso8601 }
      ))
      raise
    end

    # @spec PARTIAL-CLOSEOUT-047
    def fallback_runner_identifiers(agent_run)
      settings = agent_run.project.effective_owner&.settings
      return [] unless settings&.fallback_enabled?

      primary = agent_run.effective_runner_record&.routing_key || agent_run.effective_runner
      (Array(settings.issue_analysis_fallback_runners) +
        settings.fallback_priority_for(primary_runner: primary, identifiers: true)).uniq.first(4)
    end
  end
end
