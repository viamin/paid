# frozen_string_literal: true

module Tools
  class GetAgentRun < BaseTool
    authorize :show?, ->(args) { run_for(args.fetch(:agent_run_id)) }

    def self.tool_name = "get_agent_run"

    def self.description
      "Get details of an agent run including status, output summary, and timing."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          agent_run_id: { type: "integer", description: "The agent run ID" }
        },
        required: [ "agent_run_id" ]
      }
    end

    def perform(agent_run_id:)
      run = run_for(agent_run_id)

      {
        id: run.id,
        project_id: run.project_id,
        issue_id: run.issue_id,
        status: run.status,
        goal: run.goal,
        agent_type: run.agent_type,
        branch_name: run.branch_name,
        pull_request_url: run.pull_request_url,
        pull_request_number: run.pull_request_number,
        error_message: run.error_message,
        iterations: run.iterations,
        duration_seconds: run.duration_seconds,
        tokens_input: run.tokens_input,
        tokens_output: run.tokens_output,
        cost_cents: run.cost_cents,
        trigger_type: run.trigger_type,
        started_at: run.started_at,
        completed_at: run.completed_at,
        created_at: run.created_at
      }.merge(maintenance_fields(run))
    end

    private

    # @spec MAINT-016 — maintenance context is inspectable through the same
    # authorized surface regardless of the rollout guard.
    def maintenance_fields(run)
      return {} unless run.maintenance_goal?

      {
        maintenance: {
          type: run.maintenance_type,
          objective: run.maintenance_objective,
          recipe_version: run.maintenance_recipe_version,
          scope: run.maintenance_scope,
          scope_kind: run.maintenance_scope_kind,
          guidance: run.maintenance_guidance,
          pinned_revision: run.maintenance_pinned_revision,
          limits: run.maintenance_limits,
          report_only: true,
          report: maintenance_report(run.maintenance_report)
        }
      }
    end

    def maintenance_report(report)
      return nil unless report

      {
        outcome: report.outcome,
        resolved_scope: report.resolved_scope,
        exclusions: report.exclusions,
        completed_checks: report.completed_checks,
        incomplete_checks: report.incomplete_checks,
        evidence: report.evidence,
        findings: report.finding_occurrences.includes(:maintenance_finding).map do |occurrence|
          {
            claim: occurrence.claim, category: occurrence.category, symbols: occurrence.symbols, locations: occurrence.locations,
            supporting_evidence: occurrence.supporting_evidence, contrary_evidence: occurrence.contrary_evidence,
            evidence_source: occurrence.evidence_source, analyzer_provenance: occurrence.analyzer_provenance,
            raw_tool_confidence: occurrence.raw_tool_confidence,
            agent_assessment: occurrence.agent_assessment,
            proposed_action: occurrence.proposed_action, validation_plan: occurrence.validation_plan,
            observed_status: occurrence.observed_status, dismissal_reason: occurrence.maintenance_finding.dismissal_reason,
            verification_disposition: occurrence.verification_disposition, status: occurrence.maintenance_finding.status,
            reassessment_required: occurrence.maintenance_finding.reassessment_required
          }
        end
      }
    end

    def run_for(agent_run_id)
      @runs_by_id ||= {}
      @runs_by_id[agent_run_id] ||= policy_scope(AgentRun).find(agent_run_id)
    end
  end
end
