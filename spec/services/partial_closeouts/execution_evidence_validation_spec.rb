# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ExecutionEvidenceValidation do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project:, base_commit_sha: "abc123") }
  let(:backend) { instance_double("ExecutionBackend", identifier: "remote-a") }
  let(:capabilities) { ExecutionRunners::CapabilitySet.new(capabilities: %i[direct_exec persistent_workspace]) }
  let(:execution_result) do
    Struct.new(:values) do
      def [](key) = values[key]
      def success? = true
    end.new({ stdout: "native-analyzer 1.0", stderr: "", exit_code: 0 })
  end

  before do
    allow(ExecutionRunners).to receive(:resolve).with(backend:).and_return(ExecutionRunners::LocalDockerRunner.allocate)
    allow(ExecutionRunners::LocalDockerRunner).to receive(:capability_compatibility_for).and_return(
      ExecutionRunners::CompatibilityResult.new(compatible: true, error_message: nil)
    )
    allow(ExecutionRunners::LocalDockerRunner).to receive(:capabilities).with(backend:).and_return(capabilities)
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:cleanup_execution_environment)
    allow(agent_run).to receive(:runtime_image_selection).and_return({ "digest" => "sha256:image" })
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records bounded isolated execution output and cleanup evidence" do
    allow(agent_run).to receive(:execute_in_execution_environment).with([ "native-analyzer", "--version" ], stream: false)
      .and_return(execution_result)

    result = described_class.call(agent_run:, command: [ "native-analyzer", "--version" ], backend:)

    expect(result).to be_successful
    expect(agent_run).to have_received(:provision_execution_environment)
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.reconciliation.dig("execution_validation", "stdout")).to eq("native-analyzer 1.0")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "reports disabled sidecar rollout as setup work without provisioning" do
    FeatureFlags.disable!(:marketplace_tool_sidecars, project:)

    result = described_class.call(agent_run:, command: [ "native-analyzer", "--version" ], backend:, tool_sidecar: { "name" => "search" })

    expect(result.outcome).to eq("unavailable")
    expect(result.next_action).to include("Enable marketplace_tool_sidecars")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end
end
