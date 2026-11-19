# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project maintenance runs" do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }

  before do
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call)
      .with(project: project, goal: "maintenance")
      .and_return([ nil, "claude_code" ])
    stub_request(:get, "https://api.github.com/repos/#{project.full_name}/git/refs/heads/#{project.default_branch.presence || "main"}")
      .to_return(status: :ok, body: { object: { sha: "a" * 40 } }.to_json, headers: { "Content-Type" => "application/json" })
    allow(ProcessRunQueueJob).to receive(:perform_later)
    sign_in owner
  end

  describe "GET /projects/:project_id/maintenance_runs/new" do
    # @spec MAINT-OPT-004
    it "renders the maintenance start form for an authorized user" do
      get new_project_maintenance_run_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Maintenance run")
      expect(response.body).to include("Performance", "Test Coverage &amp; Quality")
      expect(response.body).to include("Unnecessary code")
      expect(response.body).to include("Required unless an optimization type or recipe objective is selected")
    end

    # @spec MAINT-002
    it "refuses admission while the maintenance_runs guard is disabled" do
      allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

      get new_project_maintenance_run_path(project)

      expect(response).to redirect_to(project_path(project))
      expect(flash[:alert]).to include("maintenance_runs")
    end
  end

  describe "POST /projects/:project_id/maintenance_runs" do
    # @spec MAINT-OPT-004 MAINT-OPT-005
    it "starts a selected optimization type with a free-form scope" do
      post project_maintenance_runs_path(project), params: {
        type: "performance", scope: "the account settings page"
      }

      expect(project.agent_runs.where(goal: "maintenance").sole.maintenance_type).to eq("performance")
    end

    # @spec MAINT-010
    it "starts an issue-less maintenance run from the UI" do
      expect {
        post project_maintenance_runs_path(project), params: {
          guidance: "Audit workflows A and B for shared code extraction",
          scope: "app/workflows/a.rb, app/workflows/b.rb"
        }
      }.to change { project.agent_runs.where(goal: "maintenance").count }.by(1)

      run = project.agent_runs.where(goal: "maintenance").sole
      expect(run).to have_attributes(issue: nil, status: "queued", maintenance_scope_kind: "named")
      expect(response).to redirect_to(project_agent_run_path(project, run))
    end

    # @spec MAINT-011
    it "refuses a start with neither objective nor guidance" do
      expect {
        post project_maintenance_runs_path(project), params: { scope: "app/workflows/a.rb" }
      }.not_to change { project.agent_runs.count }

      expect(response).to redirect_to(new_project_maintenance_run_path(project))
      expect(flash[:alert]).to be_present
    end

    # @spec MAINT-015
    it "returns to the form when the default branch revision is unavailable" do
      stub_request(:get, "https://api.github.com/repos/#{project.full_name}/git/refs/heads/#{project.default_branch.presence || "main"}")
        .to_return(status: :not_found, body: "{}", headers: { "Content-Type" => "application/json" })

      expect {
        post project_maintenance_runs_path(project), params: { guidance: "Audit workflow A" }
      }.not_to change { project.agent_runs.count }

      expect(response).to redirect_to(new_project_maintenance_run_path(project))
      expect(flash[:alert]).to include("Could not resolve")
    end

    # @spec MAINT-002
    it "refuses admission while the maintenance_runs guard is disabled" do
      allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

      expect {
        post project_maintenance_runs_path(project), params: { guidance: "Audit workflow A" }
      }.not_to change { project.agent_runs.count }
    end

    it "refuses an unauthorized user" do
      sign_out :user
      other_account = create(:account)
      outsider = create(:user, :owner, account: other_account)
      sign_in outsider

      post project_maintenance_runs_path(project), params: { guidance: "Audit workflow A" }

      expect(response).to have_http_status(:not_found)
      expect(project.agent_runs.where(goal: "maintenance")).to be_empty
    end
  end

  describe "inspect and cancel" do
    let(:run) do
      create(:agent_run, goal: "maintenance", project: project, issue: nil,
        custom_prompt: "Audit workflow A", maintenance_guidance: "Audit workflow A",
        maintenance_objective: "unnecessary_code", maintenance_recipe_version: "1",
        maintenance_scope: "app/workflows/a.rb", maintenance_scope_kind: "named",
        maintenance_pinned_revision: "main")
    end

    # @spec MAINT-016
    it "shows the maintenance context on the run page" do
      get project_agent_run_path(project, run)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Maintenance investigation")
      expect(response.body).to include("app/workflows/a.rb")
      expect(response.body).to include("unnecessary_code")
      expect(response.body).to include("main")
    end

    # @spec MAINT-004
    it "keeps an existing maintenance run readable and cancellable while the guard is disabled" do
      running_run = create(:agent_run, :running, goal: "maintenance", project: project, issue: nil,
        custom_prompt: "Audit workflow A", maintenance_guidance: "Audit workflow A")
      allow(AgentRunCancellationJob).to receive(:perform_later)
      allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

      get project_agent_run_path(project, running_run)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Maintenance investigation")

      expect {
        post cancel_project_agent_run_path(project, running_run)
      }.to change { running_run.reload.status }.from("running").to("cancelled")

      expect(AgentRunCancellationJob).to have_received(:perform_later)
    end
  end

  # @spec MAINT-016 MAINT-021 MAINT-025
  it "shows inspectable finding evidence and explicit unresolved scope during rollback" do
    run = create(:agent_run, :manual, :running, project:, issue: nil, goal: "maintenance", maintenance_guidance: "Inspect callbacks")
    payload = { resolved_scope: nil, completed_checks: [], incomplete_checks: [ { name: "callers", reason: "unavailable_service" } ],
      evidence: { note: "Collected preliminary trace" }, exclusions: [ "vendor callbacks" ], findings: [ {
        category: "unused_code", claim: "Legacy callback may be unused", symbols: [ "Legacy#call" ],
        locations: [ { path: "app/legacy.rb", line: 12 } ], supporting_evidence: [ "No direct callers" ],
        contrary_evidence: [ "Dynamic invocation remains possible" ], proposed_action: "Inspect registration",
        evidence_source: "agent", analyzer_provenance: {}, validation_plan: "Exercise callback registration",
        verification_disposition: "unverified"
      } ] }
    run.log!("stdout", "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->")
    Activities::CompleteMaintenanceRunActivity.new.execute(agent_run_id: run.id)
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

    get project_agent_run_path(project, run)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Scope not resolved", "Collected preliminary trace", "unavailable_service",
      "vendor callbacks", "No direct callers", "Dynamic invocation remains possible", "Inspect registration",
      "Exercise callback registration", "app/legacy.rb", "Legacy#call", "Evidence source: Agent")
  end
end
