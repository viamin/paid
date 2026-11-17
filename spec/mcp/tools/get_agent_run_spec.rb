# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetAgentRun do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe "#call" do
    it "returns agent run attributes" do
      run = create(:agent_run, :completed, :with_metrics, project: create(:project, account: account))

      result = tool.call(agent_run_id: run.id)

      expect(result).to include(
        id: run.id,
        project_id: run.project_id,
        issue_id: run.issue_id,
        status: "completed",
        goal: run.goal,
        agent_type: run.agent_type,
        pull_request_url: run.pull_request_url,
        iterations: run.iterations,
        tokens_input: run.tokens_input,
        tokens_output: run.tokens_output,
        cost_cents: run.cost_cents
      )
    end

    it "raises for runs outside the user's account" do
      other_run = create(:agent_run)

      expect { tool.call(agent_run_id: other_run.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    # @spec MAINT-016 — maintenance context is inspectable through the same
    # authorized surface regardless of the rollout guard.
    it "includes the maintenance context for maintenance runs" do
      run = create(:agent_run, project: create(:project, account: account), goal: "maintenance",
        issue: nil, custom_prompt: "Audit workflow A", maintenance_guidance: "Audit workflow A",
        maintenance_objective: "unnecessary_code", maintenance_recipe_version: "1",
        maintenance_scope: "app/workflows/a.rb", maintenance_scope_kind: "named",
        maintenance_pinned_revision: "main", maintenance_limits: { "max_execution_seconds" => 7200 })
      MaintenanceReports::Persist.call(run:, completed_checks: [ { "name" => "prompt" } ])

      result = tool.call(agent_run_id: run.id)

      expect(result[:maintenance]).to include(
        objective: "unnecessary_code",
        recipe_version: "1",
        scope: "app/workflows/a.rb",
        scope_kind: "named",
        guidance: "Audit workflow A",
        pinned_revision: "main",
        report_only: true,
        report: include(outcome: "clean", completed_checks: [ { "name" => "prompt" } ])
      )
    end

    # @spec MAINT-016 MAINT-025
    it "includes analyzer provenance for maintenance findings" do
      run = create(:agent_run, project: create(:project, account: account), goal: "maintenance",
        issue: nil, custom_prompt: "Audit workflow A", maintenance_guidance: "Audit workflow A")
      MaintenanceReports::Persist.call(run:, findings: [ {
        category: "obsolete_behavior", claim: "WorkflowA uses a retired callback", symbols: [ "WorkflowA" ], locations: [],
        analyzer_provenance: { name: "debride", version: "1.14.0" }, verification_disposition: "unverified"
      } ])

      result = tool.call(agent_run_id: run.id)

      expect(result.dig(:maintenance, :report, :findings, 0, :analyzer_provenance))
        .to eq("name" => "debride", "version" => "1.14.0")
    end

    it "omits maintenance fields for non-maintenance runs" do
      run = create(:agent_run, project: create(:project, account: account))

      expect(tool.call(agent_run_id: run.id)).not_to include(:maintenance)
    end

    it "reuses the authorized run lookup during perform" do
      run = create(:agent_run, project: create(:project, account: account))
      scope = instance_double(ActiveRecord::Relation)

      allow(tool).to receive(:policy_scope).with(AgentRun).and_return(scope)
      expect(scope).to receive(:find).once.with(run.id).and_return(run)

      tool.call(agent_run_id: run.id)
    end
  end
end
