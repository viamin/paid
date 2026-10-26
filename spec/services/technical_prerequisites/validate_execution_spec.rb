# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ValidateExecution do
  # @spec PARTIAL-CLOSEOUT-030
  it "uses a compatible isolated backend rather than the control-plane host and retains execution evidence" do
    run = create(:agent_run, base_commit_sha: "a" * 40, external_metadata: { "runtime_image" => "paid-agent:test" })
    scheduler = class_double(Containers::BackendScheduler)
    allow(scheduler).to receive(:call).with(agent_run: run).and_return(Struct.new(:candidate_hosts).new([ "remote-docker" ]))
    provisioner = instance_double(Containers::McpProvisioner)
    response = Containers::Provision::Result.success(stdout: "analyzer output", stderr: "", exit_code: 0)
    allow(run).to receive(:provision_execution_environment)
    allow(run).to receive(:execute_in_execution_environment).and_return(response)
    allow(run).to receive(:cleanup_execution_environment)

    result = described_class.call(
      agent_run: run, command: [ "native-analyzer", "--check" ], analyzer: "native-analyzer",
      prerequisite_id: "4604", scheduler:, mcp_provisioner: provisioner
    )

    expect(result).to be_succeeded
    expect(run).to have_received(:provision_execution_environment).with(container_host: "remote-docker")
    evidence = run.reload.verification_result.fetch("technical_prerequisite_validation")
    expect(evidence).to include("checkout_sha" => "a" * 40, "stdout" => "analyzer output", "exit_status" => 0, "cleanup" => "completed")
    expect(ExecutionAuditEvent.by_event_name("execution.technical_prerequisite_validated").last.metadata).to include("prerequisite_id" => "4604")
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "reports the scoped rollout action without provisioning a sidecar when the tool flag is off" do
    run = create(:agent_run, base_commit_sha: "a" * 40)
    scheduler = class_double(Containers::BackendScheduler)
    allow(scheduler).to receive(:call)
    provisioner = instance_double(Containers::McpProvisioner)
    allow(provisioner).to receive(:provision)
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: run.project).and_return(false)

    result = described_class.call(
      agent_run: run, command: [ "native-analyzer" ], analyzer: "native-analyzer", prerequisite_id: "4604",
      tool_name: "sidecar", scheduler:, mcp_provisioner: provisioner
    )

    expect(result).to be_unavailable
    expect(scheduler).not_to have_received(:call)
    expect(provisioner).not_to have_received(:provision)
    expect(run.reload.verification_result.dig("technical_prerequisite_validation", "stderr"))
      .to include("Enable marketplace_tool_sidecars")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not retry an unchanged lack of compatible backends" do
    run = create(:agent_run, base_commit_sha: "a" * 40)
    scheduler = class_double(Containers::BackendScheduler)
    allow(scheduler).to receive(:call).with(agent_run: run).and_return(Struct.new(:candidate_hosts).new([]))
    provisioner = instance_double(Containers::McpProvisioner)

    result = described_class.call(
      agent_run: run, command: [ "native-analyzer" ], analyzer: "native-analyzer", prerequisite_id: "4604",
      scheduler:, mcp_provisioner: provisioner
    )

    expect(result).to be_unavailable
    expect(run.reload.verification_result.dig("technical_prerequisite_validation", "status")).to eq("unavailable")
  end
end
