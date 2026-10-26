# frozen_string_literal: true

require "rails_helper"

class PrerequisiteExecutionEvidence::ValidateSpecBackend
  attr_reader :identifier

  def initialize(identifier:)
    @identifier = identifier
  end
end

class PrerequisiteExecutionEvidence::ValidateSpecExecutionResult
  def success? = true
  def [](key) = { stdout: "", stderr: "", exit_code: 0 }.fetch(key)
end

RSpec.describe PrerequisiteExecutionEvidence::Validate do
  # @spec PREREQUISITE-EVIDENCE-001
  # @spec PREREQUISITE-EVIDENCE-002
  # @spec PREREQUISITE-EVIDENCE-003
  # @spec PREREQUISITE-EVIDENCE-004
  let(:project) { instance_double(Project) }
  let(:backend) { instance_double(PrerequisiteExecutionEvidence::ValidateSpecBackend, identifier: "remote-docker") }
  let(:runner_class) { class_double(ExecutionRunners::LocalDockerRunner) }
  let(:runner) { instance_double(ExecutionRunners::LocalDockerRunner) }
  let(:verification_result) { {} }
  let(:agent_run) do
    instance_double(
      AgentRun,
      id: 42,
      project: project,
      container_host: "remote-docker",
      base_commit_sha: "abc123",
      external_metadata: { "image" => "paid-agent@sha256:image" },
      runner_handle: { "identifier" => "run-42" },
      tool_sidecar_snapshot: [],
      tool_sidecar_endpoints: [],
      verification_result: verification_result,
      status: "running"
    )
  end
  let(:provisioner) { instance_double(Containers::McpProvisioner, cleanup: nil) }

  before do
    allow(Containers).to receive(:backend_for).with("remote-docker").and_return(backend)
    allow(ExecutionRunners).to receive(:resolve).with(backend: backend).and_return(runner)
    allow(runner).to receive(:class).and_return(runner_class)
    allow(runner_class).to receive(:capability_compatibility_for).and_return(
      ExecutionRunners::CompatibilityResult.new(compatible: true, error_message: nil)
    )
    allow(Containers::HostReadiness).to receive(:call).and_return(
      backend => { healthy: true, remediation_hint: nil }
    )
    allow(agent_run).to receive(:update!) do |attributes|
      verification_result.replace(attributes.fetch(:verification_result))
    end
    allow(agent_run).to receive(:log!)
  end

  it "records an unavailable compatible-backend result without provisioning when runner capability is absent" do
    allow(runner_class).to receive(:capability_compatibility_for).and_return(
      ExecutionRunners::CompatibilityResult.new(compatible: false, error_message: "Runner lacks required capabilities: direct exec.")
    )
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run: agent_run, native_command: [ "knip" ], provisioner: provisioner)

    expect(result.status).to eq("unavailable")
    expect(result.evidence).to include("reason" => "runner_capability")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  it "requires scoped pilot authorization instead of enabling tool sidecars" do
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: project).and_return(false)
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(
      agent_run: agent_run,
      native_command: [ "knip" ],
      sidecar_command: [ "curl", "http://tool/health" ],
      provisioner: provisioner
    )

    expect(result.status).to eq("unavailable")
    expect(result.evidence.fetch("required_action")).to include("marketplace_tool_sidecars")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  it "executes only in the provisioned run and retains command and cleanup evidence" do
    command_result = instance_double(PrerequisiteExecutionEvidence::ValidateSpecExecutionResult)
    allow(command_result).to receive(:success?).and_return(true)
    allow(command_result).to receive(:[]).with(:stdout).and_return("native output")
    allow(command_result).to receive(:[]).with(:stderr).and_return("")
    allow(command_result).to receive(:[]).with(:exit_code).and_return(0)
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:execute_in_execution_environment).with([ "knip" ], stream: false).and_return(command_result)
    allow(agent_run).to receive(:cleanup_execution_environment).with(force: true)

    result = described_class.call(agent_run: agent_run, native_command: [ "knip" ], provisioner: provisioner)

    expect(result.status).to eq("succeeded")
    expect(result.evidence.dig("commands", 0)).to include("stdout" => "native output", "exit_code" => 0)
    expect(result.evidence.dig("cleanup", "status")).to eq("completed")
    expect(agent_run).to have_received(:execute_in_execution_environment).with([ "knip" ], stream: false)
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
  end

  it "revalidates a stale successful receipt when the requested scope changes" do
    verification_result["prerequisite_execution_validation"] = { "status" => "succeeded", "scope_digest" => "stale" }
    command_result = instance_double(PrerequisiteExecutionEvidence::ValidateSpecExecutionResult)
    allow(command_result).to receive_messages(success?: true, "[]": "")
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(command_result)
    allow(agent_run).to receive(:cleanup_execution_environment)

    result = described_class.call(agent_run: agent_run, native_command: [ "knip" ], provisioner: provisioner)

    expect(result.status).to eq("succeeded")
    expect(agent_run).to have_received(:provision_execution_environment)
  end
end
