# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteValidations::Start do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:scheduler_result) do
    Containers::BackendScheduler::Result.new(
      candidate_hosts: [ "remote-docker" ], fallback_policy: "first_healthy",
      selection_source: "default", requested_host: "local", requirements_error: nil,
      compatibility_failures: {}, health_failures: {}
    )
  end

  before do
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result)
  end

  # @spec PREREQUISITE-VALIDATION-001
  it "uses compatible execution-host selection instead of the operator workspace" do
    result = described_class.call(issue:, actor:)

    expect(result).to be_success
    expect(result.agent_run.goal).to eq("prerequisite_validation")
    expect(result.agent_run.container_host).to eq("remote-docker")
    expect(result.agent_run.external_metadata.dig("prerequisite_validation", "artifact_contract")).to include("cleanup")
    expect(Containers::BackendScheduler).to have_received(:call).with(agent_run: result.agent_run)
  end

  # @spec PREREQUISITE-VALIDATION-001
  it "names the rollout authorization instead of silently enabling tool sidecars" do
    create(:agent_run, project:, issue:, tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer" } ])
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(false)

    result = described_class.call(issue:, actor:)

    expect(result).not_to be_success
    expect(result.code).to eq(:tool_rollout_disabled)
    expect(result.message).to include("marketplace_tool_sidecars")
    expect(issue.agent_runs.where(goal: "prerequisite_validation")).to be_empty
  end
end
