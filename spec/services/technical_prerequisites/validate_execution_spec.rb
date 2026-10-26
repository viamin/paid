# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ValidateExecution do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project:, base_commit_sha: "a" * 40) }
  let(:execution_runner) { instance_double(ExecutionRunners::Base, provision_mcp_servers: {}, cleanup_mcp_servers: nil) }
  let(:execution_environment) { instance_double(Containers::Provision) }
  let(:git_operations) { instance_double(Containers::GitOperations, clone_and_restore_branch: nil, head_sha: "b" * 40) }

  before do
    allow(Containers::Provision).to receive(:reconnect).and_return(execution_environment)
    allow(Containers::GitOperations).to receive(:new).and_return(git_operations)
    allow(agent_run).to receive(:tool_sidecar_endpoints).and_return([ { "name" => "analyzer", "url" => "http://analyzer:8080" } ])
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records an exact rollout approval action instead of retrying when the tool flag is off" do
    AgentRun.where(id: agent_run.id).update_all(tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer" } ])
    agent_run.reload
    scheduler = instance_double(Containers::BackendScheduler, call: scheduler_result([ "remote" ]))
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler.call)
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

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
    allow(agent_run).to receive(:execute_in_execution_environment).with(
      [ "analyzer", "--version" ],
      stream: false,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    )
      .and_return(stdout: "analyzer 1.0", stderr: "", exit_code: 0)
    allow(agent_run).to receive(:cleanup_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result).to be_success
    expect(agent_run).to have_received(:provision_execution_environment).with(container_host: "remote")
    expect(git_operations).to have_received(:clone_and_restore_branch).with(
      branch_name: agent_run.branch_name,
      base_commit_sha: "a" * 40
    )
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "native")).to include("stdout" => "analyzer 1.0", "exit_code" => 0)
    expect(agent_run.verification_result.dig("technical_prerequisite_validation", "checkout")).to eq("b" * 40)
    expect(agent_run.verification_result.dig("technical_prerequisite_validation", "tool_endpoints"))
      .to contain_exactly(include("name" => "analyzer"))
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "provisions and cleans up sidecars through the selected execution runner" do
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([ "remote" ]))
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(true)
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:cleanup_execution_environment)

    expect(execution_runner).to receive(:provision_mcp_servers).with(
      agent_run:,
      network: Containers::Provision.network_for(agent_run:)
    ).ordered
    expect(agent_run).to receive(:execute_in_execution_environment).with(
      [ "analyzer", "--version" ],
      stream: false,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).ordered.and_return(stdout: "analyzer 1.0", stderr: "", exit_code: 0)

    expect(execution_runner).to receive(:cleanup_mcp_servers).with(agent_run:).ordered

    described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records no compatible backend as unavailable without running an unchanged validation" do
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([]))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to eq("Configure or restore a compatible execution backend for this project.")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "preserves a capability-requirements failure as the unavailable setup action" do
    error = 'Runtime image reference "retired" is deprecated'
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([], requirements_error: error))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to eq("Resolve execution requirements: #{error}")
    expect(agent_run.reload.verification_result.dig(
      "technical_prerequisite_validation", "inspection", "requirements_error"
    )).to eq(error)
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  def scheduler_result(hosts, requirements_error: nil)
    Containers::BackendScheduler::Result.new(
      candidate_hosts: hosts,
      requirements_error:,
      compatibility_failures: {},
      health_failures: {}
    )
  end
end
