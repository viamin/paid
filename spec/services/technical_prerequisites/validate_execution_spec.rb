# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ValidateExecution do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }
  let(:source_run) { create(:agent_run, :completed, project:, issue:) }
  let(:agent_run) do
    create(:agent_run, :queued, project:, issue:, base_commit_sha: "a" * 40,
      branch_name: "prerequisite-validation-abc", external_metadata: {
        TechnicalPrerequisites::RECIPE_KEY => { "source_run_id" => source_run.id }
      })
  end
  let(:execution_runner) { instance_double(ExecutionRunners::Base, provision_mcp_servers: {}, cleanup_mcp_servers: nil) }
  let(:execution_environment) { instance_double(Containers::Provision) }
  let(:git_operations) do
    instance_double(Containers::GitOperations, clone_and_checkout_pinned_commit: "a" * 40, head_sha: "b" * 40)
  end
  let(:sidecar_endpoints) { [ { "name" => "analyzer", "url" => "http://analyzer:8080" } ] }

  before do
    allow(Containers::Provision).to receive(:reconnect).and_return(execution_environment)
    allow(Containers::GitOperations).to receive(:new).and_return(git_operations)
    allow(agent_run).to receive(:tool_sidecar_endpoints).and_return(sidecar_endpoints)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records an exact rollout approval action instead of retrying when the tool flag is off" do
    AgentRun.where(id: agent_run.id).update_all(tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer" } ])
    agent_run.reload
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result([ "remote" ]))
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("unavailable")
    expect(result.setup_action).to include("marketplace_tool_sidecars")
    expect(agent_run).not_to have_received(:provision_execution_environment)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("attempted" => false)
    expect(source_run.reload.reconciliation.dig("technical_prerequisite_evidence", "status")).to eq("unavailable")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "uses a compatible isolated host, captures command evidence, and cleans up" do
    stub_compatible_host
    stub_provisioning
    stub_command_execution

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result).to be_success
    expect(agent_run).to have_received(:provision_execution_environment).with(container_host: "remote")
    expect(git_operations).to have_received(:clone_and_checkout_pinned_commit).with(
      branch_name: agent_run.branch_name,
      base_commit_sha: "a" * 40
    )
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "native")).to include("stdout" => "analyzer 1.0", "exit_code" => 0)
    expect(agent_run.verification_result.dig("technical_prerequisite_validation", "checkout")).to eq("b" * 40)
    expect(agent_run.verification_result.dig("technical_prerequisite_validation", "tool_endpoints"))
      .to contain_exactly(include("name" => "analyzer"))
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup")).to include("completed" => true)
    expect(source_run.reload.reconciliation.dig("technical_prerequisite_evidence", "validation_run_id")).to eq(agent_run.id)
    expect(source_run.reconciliation.dig("technical_prerequisite_evidence", "cleanup")).to include("completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not provision when the running validation is cancelled during capability inspection" do
    agent_run.update!(status: "running")
    allow(Containers::BackendScheduler).to receive(:call) do
      agent_run.update!(status: "cancelled", completed_at: Time.current)
      scheduler_result([ "remote" ])
    end
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(true)
    allow(agent_run).to receive(:provision_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("cancelled")
    expect(agent_run).not_to have_received(:provision_execution_environment)
    expect(agent_run.reload.status).to eq("cancelled")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "cleans up without executing when the running validation is cancelled before command execution" do
    agent_run.update!(status: "running")
    stub_compatible_host
    stub_provisioning
    allow(execution_runner).to receive(:provision_mcp_servers) do
      agent_run.update!(status: "cancelled", completed_at: Time.current)
    end
    allow(agent_run).to receive(:execute_in_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("cancelled")
    expect(agent_run).not_to have_received(:execute_in_execution_environment)
    expect(execution_runner).to have_received(:cleanup_mcp_servers).with(agent_run:)
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.status).to eq("cancelled")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records a flat resolved image identity and digest" do
    agent_run.record_runtime_image_selection!(
      "requested_image" => "paid-agent:latest",
      "resolved_image" => "registry.example/paid-agent@sha256:abc",
      "digest" => "sha256:abc"
    )
    stub_compatible_host
    stub_provisioning
    stub_command_execution

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.evidence).to include(
      "image" => "registry.example/paid-agent@sha256:abc",
      "image_digest" => "sha256:abc"
    )
    expect(result.evidence.fetch("image_selection")).to include("resolved_image" => "registry.example/paid-agent@sha256:abc")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "plans the inspected host so the container lands on the host the capability decision approved" do
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(stdout: "", stderr: "", exit_code: 0)

    described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(agent_run.reload.external_metadata["planned_container_host"]).to eq("remote")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "provisions and cleans up sidecars through the selected execution runner" do
    stub_compatible_host
    stub_provisioning

    expect(execution_runner).to receive(:provision_mcp_servers).with(
      agent_run:,
      network: Containers::Provision.network_for(agent_run:)
    ).ordered
    expect(agent_run).to receive(:execute_in_execution_environment).with(
      [ "analyzer", "--version" ],
      stream: false,
      timeout: described_class::COMMAND_TIMEOUT,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).ordered.and_return(stdout: "analyzer 1.0", stderr: "", exit_code: 0)

    expect(execution_runner).to receive(:cleanup_mcp_servers).with(agent_run:).ordered

    described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "passes a reviewed shell recipe through unchanged" do
    stub_compatible_host
    stub_provisioning
    command = "bundle exec rubocop | tee rubocop.log"
    expect(agent_run).to receive(:execute_in_execution_environment).with(
      command,
      timeout: described_class::COMMAND_TIMEOUT,
      stream: false,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).and_return(stdout: "", stderr: "", exit_code: 0)

    described_class.call(agent_run:, native_command: command, execution_runner:)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records the attached tool identity and endpoint for a native-plus-sidecar validation" do
    AgentRun.where(id: agent_run.id).update_all(
      tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/analyzer", "version" => "1.2.3" } ]
    )
    agent_run.reload
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive_messages(
      execute_in_execution_environment: { stdout: "analyzer 1.0", stderr: "", exit_code: 0 },
      tool_sidecar_container_ids: [ "container-1" ]
    )

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result).to be_success
    expect(result.evidence["tool_identity"]).to contain_exactly(include("name" => "analyzer", "image" => "example/analyzer"))
    expect(result.evidence["tool_sidecars"]).to eq([ "container-1" ])
    expect(result.evidence["tool_endpoints"]).to contain_exactly(include("url" => "http://analyzer:8080"))
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records the provisioner's rejection when the attached tool image is not allowed" do
    AgentRun.where(id: agent_run.id).update_all(
      tool_sidecar_snapshot: [ { "name" => "analyzer", "image" => "example/denied" } ]
    )
    agent_run.reload
    stub_compatible_host
    stub_provisioning
    allow(execution_runner).to receive(:provision_mcp_servers).and_raise(
      Containers::McpProvisioner::Error, 'Image "example/denied" is not in the allowed service images list for this account'
    )

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence["error"]).to include("is not in the allowed service images list")
    expect(result.evidence["checkout"]).to eq("b" * 40)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "cleans up resources when provisioning fails before it records a container" do
    stub_compatible_host
    allow(agent_run).to receive(:provision_execution_environment)
      .and_raise(Containers::Provision::Error, "image pull failed")
    allow(agent_run).to receive(:cleanup_execution_environment)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("failed")
    expect(agent_run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(agent_run.reload.verification_result.dig("technical_prerequisite_validation", "cleanup"))
      .to include("attempted" => true, "completed" => true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records a failed outcome with the analyzer output when the command exits non-zero" do
    stub_compatible_host
    stub_provisioning
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(stdout: "boom", stderr: "missing tool", exit_code: 3)

    result = described_class.call(agent_run:, native_command: [ "analyzer", "--version" ], execution_runner:)

    expect(result.status).to eq("failed")
    expect(result.evidence["native"]).to include("stdout" => "boom", "stderr" => "missing tool", "exit_code" => 3)
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

  def stub_compatible_host(hosts = [ "remote" ])
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler_result(hosts))
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(true)
  end

  def stub_command_execution(stdout: "analyzer 1.0", stderr: "", exit_code: 0)
    allow(agent_run).to receive(:execute_in_execution_environment).with(
      [ "analyzer", "--version" ],
      stream: false,
      timeout: described_class::COMMAND_TIMEOUT,
      env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => '[{"name":"analyzer","url":"http://analyzer:8080"}]' }
    ).and_return(stdout:, stderr:, exit_code:)
  end

  def stub_provisioning
    allow(agent_run).to receive_messages(
      provision_execution_environment: nil,
      cleanup_execution_environment: nil
    )
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
