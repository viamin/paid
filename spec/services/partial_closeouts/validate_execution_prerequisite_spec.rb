# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ValidateExecutionPrerequisite do
  # @spec PARTIAL-CLOSEOUT-030 PARTIAL-CLOSEOUT-031 PARTIAL-CLOSEOUT-032
  it "records unavailable capability evidence without provisioning or using the control-plane host" do
    run = create(:agent_run, verification_result: {})
    backend = instance_double(Containers::Backends::Base, identifier: "remote-no-exec")
    runner = ExecutionRunners::LocalDockerRunner.new
    allow(Containers).to receive(:backend_for).and_return(backend)
    allow(run).to receive(:provision_execution_environment)
    allow(ExecutionRunners).to receive(:resolve).and_return(runner)
    allow(ExecutionRunners::LocalDockerRunner).to receive(:capabilities).with(backend: backend).and_return(
      ExecutionRunners::CapabilitySet.new(capabilities: [ :persistent_workspace ])
    )

    result = described_class.call(agent_run: run, native_command: [ "sh", "-c", "analyzer /workspace" ])

    expect(result.status).to eq("unavailable")
    expect(run.reload.verification_result.dig("execution_prerequisite_validation", "evidence", "missing_capabilities")).to eq([ "direct_exec" ])
    expect(run).not_to have_received(:provision_execution_environment)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "requires the scoped sidecar rollout authorization without provisioning" do
    run = create(:agent_run, verification_result: {})
    backend = instance_double(Containers::Backends::Base, identifier: "compatible")
    runner = ExecutionRunners::LocalDockerRunner.new
    allow(Containers).to receive(:backend_for).and_return(backend)
    allow(ExecutionRunners).to receive(:resolve).and_return(runner)
    allow(ExecutionRunners::LocalDockerRunner).to receive(:capabilities).with(backend: backend).and_return(
      ExecutionRunners::CapabilitySet.new(capabilities: [ :direct_exec ])
    )
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: run.project).and_return(false)
    allow(run).to receive(:provision_execution_environment)

    result = described_class.call(
      agent_run: run,
      native_command: [ "sh", "-c", "analyzer /workspace" ],
      sidecar_command: [ "sh", "-c", "curl http://tool" ]
    )

    expect(result.status).to eq("unavailable")
    expect(result.next_action).to include("scoped pilot authorization")
    expect(run).not_to have_received(:provision_execution_environment)
  end
end
