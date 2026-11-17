# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Maintenance runs API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:headers) { { "Authorization" => "Bearer #{plaintext}", "Content-Type" => "application/json" } }

  before do
    create(:personal_access_token, user:, account:, name: "Maintenance", scopes: [ "inbox" ], plaintext:)
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call)
      .with(project: project, goal: "maintenance")
      .and_return([ nil, "claude_code" ])
    stub_request(:get, "https://api.github.com/repos/#{project.full_name}/git/refs/heads/#{project.default_branch.presence || "main"}")
      .to_return(status: :ok, body: { object: { sha: "a" * 40 } }.to_json, headers: { "Content-Type" => "application/json" })
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  # @spec MAINT-010 MAINT-011
  it "starts an issue-less maintenance run with the same project authorization" do
    expect {
      post "/api/v1/projects/#{project.id}/maintenance_runs", params: {
        guidance: "Audit workflow A", scope: "app/workflows/a.rb"
      }.to_json, headers: headers
    }.to change { project.agent_runs.where(goal: "maintenance").count }.by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("project_id" => project.id, "goal" => "maintenance", "status" => "queued")
  end

  # @spec MAINT-OPT-004
  it "lists the same curated types available to the authenticated project API" do
    get "/api/v1/projects/#{project.id}/maintenance_runs/types", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("types").map { |type| type.fetch("key") }).to eq(MaintenanceRuns::OptimizationTypes.keys)
  end

  # @spec MAINT-OPT-009
  it "hides the type menu while the maintenance_runs guard is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

    get "/api/v1/projects/#{project.id}/maintenance_runs/types", headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("maintenance_run_unavailable")
  end

  # @spec MAINT-OPT-004 MAINT-OPT-006 MAINT-OPT-007
  it "starts and returns an unmapped type as a custom-objective snapshot" do
    post "/api/v1/projects/#{project.id}/maintenance_runs", params: {
      type: "future_type", guidance: "Investigate the request path"
    }.to_json, headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("maintenance", "type")).to eq("future_type")
  end

  # @spec MAINT-OPT-006
  it "returns a validation error when type exceeds the snapshot limit" do
    expect {
      post "/api/v1/projects/#{project.id}/maintenance_runs", params: {
        type: "x" * 101
      }.to_json, headers: headers
    }.not_to change { project.agent_runs.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("maintenance_run_unavailable")
    expect(response.parsed_body.dig("error", "message")).to include("100 characters or fewer")
  end

  # @spec MAINT-002
  it "refuses API admission while the maintenance_runs guard is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

    expect {
      post "/api/v1/projects/#{project.id}/maintenance_runs", params: { guidance: "Audit workflow A" }.to_json, headers: headers
    }.not_to change { project.agent_runs.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("maintenance_run_unavailable")
  end

  # @spec MAINT-016
  it "inspects a maintenance run through the API" do
    run = create(:agent_run, project:, goal: "maintenance", issue: nil, custom_prompt: "Audit workflow A",
      maintenance_guidance: "Audit workflow A", maintenance_scope: "app/workflows/a.rb", maintenance_scope_kind: "named")
    MaintenanceReports::Persist.call(run:, completed_checks: [ { "name" => "prompt" } ])

    get "/api/v1/projects/#{project.id}/maintenance_runs/#{run.id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => run.id, "goal" => "maintenance", "scope" => "app/workflows/a.rb")
    expect(response.parsed_body.fetch("maintenance")).to include(
      "guidance" => "Audit workflow A", "scope" => "app/workflows/a.rb", "report_only" => true,
      "report" => include("outcome" => "clean", "completed_checks" => [ { "name" => "prompt" } ])
    )
  end

  # @spec MAINT-016 MAINT-025
  it "exposes analyzer provenance for report findings" do
    run = create(:agent_run, project:, goal: "maintenance", issue: nil, custom_prompt: "Audit workflow A",
      maintenance_guidance: "Audit workflow A")
    MaintenanceReports::Persist.call(run:, findings: [ {
      category: "obsolete_behavior", claim: "WorkflowA uses a retired callback", symbols: [ "WorkflowA" ], locations: [],
      analyzer_provenance: { name: "debride", version: "1.14.0" }, verification_disposition: "unverified"
    } ])

    run.maintenance_report.finding_occurrences.sole.maintenance_finding.dismiss!(reason: "Intentional compatibility callback")

    get "/api/v1/projects/#{project.id}/maintenance_runs/#{run.id}", headers: headers

    expect(response.parsed_body.dig("maintenance", "report", "findings", 0, "analyzer_provenance"))
      .to eq("name" => "debride", "version" => "1.14.0")
    expect(response.parsed_body.dig("maintenance", "report", "findings", 0)).to include(
      "observed_status" => "open", "status" => "dismissed", "dismissal_reason" => "Intentional compatibility callback"
    )
  end

  # @spec MAINT-017
  it "cancels an in-flight maintenance run through the API" do
    run = create(:agent_run, :running, project:, goal: "maintenance", issue: nil, custom_prompt: "Audit workflow A",
      maintenance_guidance: "Audit workflow A")
    allow(AgentRunCancellationJob).to receive(:perform_later)

    post "/api/v1/projects/#{project.id}/maintenance_runs/#{run.id}/cancel", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => run.id, "status" => "cancelled")
    expect(AgentRunCancellationJob).to have_received(:perform_later).with(run.id)
  end

  it "keeps other accounts' maintenance runs invisible" do
    other_run = create(:agent_run, project: create(:project), goal: "maintenance", issue: nil, custom_prompt: "Audit workflow A",
      maintenance_guidance: "Audit workflow A")

    get "/api/v1/projects/#{other_run.project_id}/maintenance_runs/#{other_run.id}", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  # @spec MAINT-010
  it "does not let a bearer token start a run for another account's project" do
    other_project = create(:project)

    expect {
      post "/api/v1/projects/#{other_project.id}/maintenance_runs", params: { guidance: "Audit workflow A" }.to_json, headers: headers
    }.not_to change { other_project.agent_runs.count }

    expect(response).to have_http_status(:not_found)
  end
end
