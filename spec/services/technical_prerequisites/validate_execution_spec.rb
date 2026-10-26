# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ValidateExecution do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project:, base_commit_sha: "a" * 40) }
  let(:provisioner) { instance_double(Containers::McpProvisioner, provision: {}, cleanup: nil) }

  # @spec PARTIAL-CLOSEOUT-030
  it "records an exact rollout approval action instead of retrying when the tool flag is off" do
    AgentRun.where(id: agent_run.id).update_all(tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer" } ])
    agent_run.reload
    scheduler = instance_double(Containers::BackendScheduler, call: scheduler_result([ "remote" ]))
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler.call)
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], provisioner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to include("marketplace_tool_sidecars")
    expect(agent_run).not_to have_received(:provision_execution_environment)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("attempted" => false)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "uses a compatible isolated host, captures command evidence, and cleans up" do
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([ "remote" ]))
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(true)
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:execute_in_execution_environment).with([ "analyzer", "--version" ], stream: false)
      .and_return(stdout: "analyzer 1.0", stderr: "", exit_code: 0)
    allow(agent_run).to receive(:cleanup_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], provisioner:)

    expect(result).to be_success
    expect(agent_run).to have_received(:provision_execution_environment).with(container_host: "remote")
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "native")).to include("stdout" => "analyzer 1.0", "exit_code" => 0)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records no compatible backend as unavailable without running an unchanged validation" do
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([]))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], provisioner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to eq("Configure or restore a compatible execution backend for this project.")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  def scheduler_result(hosts)
    Containers::BackendScheduler::Result.new(candidate_hosts: hosts, compatibility_failures: {}, health_failures: {})
  end
end
