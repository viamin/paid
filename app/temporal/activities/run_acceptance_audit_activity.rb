# frozen_string_literal: true

module Activities
  # Refreshes persisted closeout evidence for an admitted report-only audit.
  # It intentionally does not use AnalyzeIssueActivity: that activity's
  # readiness verdict creates implementation follow-up work.
  # @spec PARTIAL-CLOSEOUT-027
  class RunAcceptanceAuditActivity < BaseActivity
    activity_name "RunAcceptanceAudit"
    MAX_ASSESSMENT_TIMEOUT = 300

    def execute(input) # @spec PARTIAL-CLOSEOUT-049 PARTIAL-CLOSEOUT-058
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "run_acceptance_audit",
        phase_group: "agent", agent_run: agent_run) do
        agent_run.start!
        fallbacks = Llm::AnalyzePartialCloseout.fallback_runner_identifiers_for(agent_run)
        assessment = assess(agent_run, fallbacks)
        snapshot = PartialCloseouts::Assessment.snapshot(agent_run, assessment)
        record_assessment_and_route_drift(agent_run, snapshot)
        PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: snapshot)
        PartialCloseouts::Reconcile.call(agent_run:, assessment: snapshot)
        agent_run.complete!
        if agent_run.continuation_request&.evidence&.dig("closeout_policy_signature").present?
          AutoResolveCloseoutJob.perform_later(agent_run.id)
        end
        ProcessRunQueueJob.perform_later
        { agent_run_id: agent_run.id, assessment_recorded: true }
      end
    end

    private

    # @spec PROJECT-DELEGATION-002 — the audit just re-recorded this issue's
    # acceptance criteria, so checkpoints settled against an earlier
    # acceptance revision get one focused, deduplicated re-decision through
    # the same drift handler a merged design amendment uses.
    def route_acceptance_drift(agent_run)
      ProjectDelegation::IntentCheckpoint::RouteDrift.on_acceptance_change(issue: agent_run.issue)
    end

    # Settlement captures the canonical acceptance token while holding this
    # same issue lock. That makes the audit update and its drift routing one
    # ordered operation: either settlement sees this assessment, or routing
    # sees the committed settlement and opens the focused re-decision.
    def record_assessment_and_route_drift(agent_run, snapshot)
      agent_run.issue.with_lock do
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => snapshot))
        route_acceptance_drift(agent_run)
      end
    end

    def assess(agent_run, fallbacks) # @spec LLM-ROUTING-005 LLM-ROUTING-006 LLM-ROUTING-010
      Llm::AnalyzePartialCloseout.call(agent_run: agent_run,
        fallback_runner_identifiers: fallbacks,
        timeout: [ Llm::AnalyzePartialCloseout::TIMEOUT * (fallbacks.size + 1), MAX_ASSESSMENT_TIMEOUT ].min)
    rescue Llm::AnalyzePartialCloseout::AssessmentFailure => error
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(
        "acceptance_audit_failure" => failure_diagnostic(error)
      ))
      raise
    end

    def failure_diagnostic(error)
      PartialCloseouts::AcceptanceAuditFailure.safe_diagnostic(error.diagnostic).merge("at" => Time.current.iso8601)
    end
  end
end
