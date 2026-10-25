# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExecutionPrerequisites::Validate do
  # @spec PARTIAL-CLOSEOUT-028
  let(:agent_run) { create(:agent_run, synthetic: true, goal: "analyze_issue") }

  it "records an actionable rollout authorization failure without provisioning" do
    agent_run = create(:agent_run, synthetic: true, goal: "analyze_issue", tool_sidecar_snapshot: [ { "name" => "analyzer" } ])
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: agent_run.project).and_return(false)
    allow(agent_run).to receive(:cleanup_execution_environment)
    expect(agent_run).not_to receive(:provision_execution_environment)

    result = described_class.call(agent_run: agent_run)

    expect(result).to include("status" => "unavailable")
    expect(result.fetch("reason")).to include("marketplace_tool_sidecars")
    expect(agent_run.reload.verification_result).to include("cleanup" => "succeeded")
  end

  it "records native stdout, stderr, exit status, and cleanup from the isolated environment" do
    result = Containers::Provision::Result.success(stdout: "ruby 3.4", stderr: "", exit_code: 0)
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:execute_in_execution_environment).with([ "ruby", "--version" ], stream: false).and_return(result)
    allow(agent_run).to receive(:cleanup_execution_environment)

    artifact = described_class.call(agent_run: agent_run)

    expect(artifact).to include("status" => "succeeded", "stdout" => "ruby 3.4", "exit_code" => 0)
    expect(agent_run.reload.verification_result).to include("cleanup" => "succeeded")
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
  end
end
