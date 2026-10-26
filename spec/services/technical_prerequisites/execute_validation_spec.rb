# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ExecuteValidation do
  # @spec TECHNICAL-PREREQUISITE-001
  let(:agent_run) { create(:agent_run, container_id: "isolated-container", base_commit_sha: "pinned-sha", tool_sidecar_endpoints: [ { "url" => "http://tool" } ]) }

  it "executes only through the provisioned environment and records complete evidence" do
    result = Containers::Provision::Result.success(stdout: "native output", stderr: "", exit_code: 0)
    allow(agent_run).to receive(:execute_in_execution_environment).with([ "native-analyzer", "check" ], timeout: 30, stream: false).and_return(result)

    outcome = described_class.call(agent_run:, command: [ "native-analyzer", "check" ], analyzer: "native-analyzer", timeout: 30)

    expect(outcome).to be_success
    expect(outcome.evidence).to include("status" => "succeeded", "stdout" => "native output", "exit_code" => 0, "checkout" => "pinned-sha")
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "tool_endpoints")).to eq([ { "url" => "http://tool" } ])
  end

  it "shows the rollout authorization needed instead of enabling sidecars" do
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: agent_run.project).and_return(false)
    allow(agent_run).to receive(:execute_in_execution_environment)

    outcome = described_class.call(agent_run:, command: [ "native-analyzer" ], analyzer: "native-analyzer", tool: "allowlisted-tool")

    expect(outcome.status).to eq("setup_required")
    expect(outcome.setup_action).to include("Enable marketplace tool sidecars")
    expect(agent_run).not_to have_received(:execute_in_execution_environment)
  end
end
