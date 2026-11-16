# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::StartMaintenanceRun do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  before do
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call)
      .with(project: project, goal: "maintenance")
      .and_return([ nil, "claude_code" ])
    stub_request(:get, "https://api.github.com/repos/#{project.full_name}/git/refs/heads/#{project.default_branch.presence || "main"}")
      .to_return(status: :ok, body: { object: { sha: "a" * 40 } }.to_json, headers: { "Content-Type" => "application/json" })
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  describe ".write_operation?" do
    it "returns true" do
      expect(described_class.write_operation?).to be(true)
    end
  end

  # @spec MAINT-OPT-004
  it "publishes the explicitly confirmed write tool on the MCP surface" do
    definitions = Tools::Registry.mcp_definitions_for(user: user, session: session)
    definition = definitions.find { |candidate| candidate[:name] == "start_maintenance_run" }

    expect(definition).to include(name: "start_maintenance_run")
    expect(definition.dig(:inputSchema, :properties, :confirmed)).to include(type: "boolean")
    expect(definition.dig(:inputSchema, :properties, :type, :enum)).to eq(MaintenanceRuns::OptimizationTypes.keys)
  end

  # @spec MAINT-OPT-004 MAINT-OPT-005
  it "starts the selected type from chat with the same project authorization" do
    tool.call(project_id: project.id, type: "performance", scope: "the dashboard", confirmed: true)

    expect(project.agent_runs.sole.maintenance_type).to eq("performance")
  end

  # @spec MAINT-002
  it "refuses admission identically while the maintenance_runs guard is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, project:).and_return(false)

    expect {
      tool.call(project_id: project.id, guidance: "Audit workflow A", confirmed: true)
    }.to raise_error(MaintenanceRuns::Start::FeatureDisabledError)
  end

  it "requires confirmation" do
    expect {
      tool.call(project_id: project.id, guidance: "Audit workflow A", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  # @spec MAINT-011
  it "requires an objective or nonblank guidance" do
    expect {
      tool.call(project_id: project.id, scope: "app/workflows/a.rb", confirmed: true)
    }.to raise_error(MaintenanceRuns::Start::MissingObjectiveError)
  end

  # @spec MAINT-010
  it "starts a maintenance run and reports the resolved scope kind" do
    result = tool.call(
      project_id: project.id,
      guidance: "Audit workflows A and B for shared code extraction",
      scope: "workflows A and B",
      confirmed: true
    )

    run = project.agent_runs.sole
    expect(run).to have_attributes(goal: "maintenance", status: "queued", issue: nil)
    expect(result).to include(id: run.id, status: "queued", goal: "maintenance")
    expect(result[:scope_kind]).to eq("named")
  end

  # @spec MAINT-014
  it "reports a broad scope when no scope is supplied" do
    result = tool.call(project_id: project.id, guidance: "Audit for unused code", confirmed: true)

    expect(result[:scope_kind]).to eq("broad")
  end

  it "refuses runs for a project outside the user's account" do
    other_account = create(:account)
    other_project = create(:project, account: other_account)

    expect {
      tool.call(project_id: other_project.id, guidance: "Audit workflow A", confirmed: true)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  # @spec MAINT-016
  it "is not advertised while the maintenance_runs guard is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:maintenance_runs, anything).and_return(false)

    expect(described_class.available_to?(user: user)).to be(false)
  end
end
