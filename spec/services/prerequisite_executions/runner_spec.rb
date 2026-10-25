# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteExecutions::Runner do # @spec PREREQ-EXEC-007 # @spec PREREQ-EXEC-008 # @spec PREREQ-EXEC-009 # @spec PREREQ-EXEC-010 # @spec PREREQ-EXEC-011 # @spec PREREQ-EXEC-012 # @spec PREREQ-EXEC-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:validation) { create(:prerequisite_execution_validation, :with_agent_run, project: project, issue: issue) }
  let(:run) { validation.agent_run }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git) do
    instance_double(Containers::GitOperations,
      clone_and_checkout_branch: nil,
      head_sha: "0123456789abcdef0123456789abcdef01234567")
  end
  let(:mcp_provisioner) { instance_double(Containers::McpProvisioner) }
  let(:runner) { described_class.new(validation, mcp_provisioner: mcp_provisioner) }

  before do
    FeatureFlags.flipper.features.each(&:remove)
    # Every fetch of the validation's run resolves to the same stubbed
    # instance, including reloads inside the runner and the shared cleanup.
    allow(validation).to receive(:agent_run).and_return(run)
    allow(run).to receive(:provision_execution_environment) do
      run.update_columns(container_id: "run-1", container_host: "local")
    end
    allow(run).to receive(:cleanup_execution_environment) { run.update_columns(container_id: nil) }
    allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
    allow(Containers::GitOperations).to receive(:new).and_return(git)
    allow(mcp_provisioner).to receive(:cleanup_tool_sidecars) { run.update_columns(tool_sidecar_container_ids: []) }
    stub_container_image_inspect("paid-agent:latest")
  end

  def stub_container_image_inspect(image)
    backend = instance_double(Containers::Backends::LocalDocker)
    container = instance_double(Docker::Container, json: { "Config" => { "Image" => image } })
    allow(Containers).to receive_messages(backend: backend, backend_for: backend)
    allow(backend).to receive(:get_container).and_return(container)
  end

  def execute_result(exit_code: 0, stdout: "", stderr: "")
    { exit_code: exit_code, stdout: stdout, stderr: stderr }
  end

  def contract_with_tool
    validation.update!(contract: validation.contract.merge(
      "tool" => { "marketplace_entry_id" => 42, "marketplace_entry_version_id" => 7, "name" => "analyzer", "image" => "acme/analyzer:latest" },
      "steps" => [
        { "key" => "native_analyzer", "command" => validation.contract["native_command"] },
        { "key" => "tool_sidecar" }
      ]
    ))
  end

  def stub_native_command(result = execute_result)
    allow(run).to receive(:execute_in_execution_environment)
      .with("bin/lint", timeout: described_class::DEFAULT_TIMEOUT_SECONDS, stream: false)
      .and_return(result)
  end

  describe "successful native-only lifecycle" do
    # @spec PREREQ-EXEC-009
    it "runs the analyzer through the run's execution environment and records bounded output" do
      stub_native_command(execute_result(stdout: "ok" * 20_000))

      runner.call

      expect(validation.reload.status).to eq("succeeded")
      native_step = validation.step_result("native_analyzer")
      expect(native_step["exit_code"]).to eq(0)
      expect(native_step["stdout"].length).to eq(described_class::OUTPUT_BOUND_BYTES)
      expect(validation.agent_run.reload.status).to eq("completed")
    end

    # @spec PREREQ-EXEC-007
    it "provisions through the AgentRun contract inside a Paid-managed isolated workspace" do
      stub_native_command

      runner.call

      expect(run).to have_received(:provision_execution_environment)
      expect(run).to have_received(:execute_in_execution_environment)
      expect(run).to have_received(:cleanup_execution_environment)
      expect(run.worktree_path).to include("paid-prereq-validation-")
    end

    # @spec PREREQ-EXEC-008
    it "records the resolved checkout commit and container identity as evidence" do
      stub_native_command

      runner.call

      expect(git).to have_received(:clone_and_checkout_branch).with(branch_name: "main", pull_request_number: nil, persist: false)
      identity = validation.reload.evidence["identity"]
      expect(identity.dig("checkout", "commit")).to eq("0123456789abcdef0123456789abcdef01234567")
      expect(identity.dig("run", "container_id")).to eq("run-1")
      expect(identity.dig("run", "image")).to eq("paid-agent:latest")
      expect(run.reload.base_commit_sha).to eq("0123456789abcdef0123456789abcdef01234567")
    end

    # @spec PREREQ-EXEC-012
    it "records cleanup evidence for the run container and unprovisioned sidecars" do
      stub_native_command

      runner.call

      cleanup = validation.reload.evidence["cleanup"]
      expect(cleanup["run_container"]).to eq("cleaned")
      expect(cleanup["sidecars"]).to eq("not_provisioned")
    end
  end

  describe "native plus sidecar lifecycle" do
    # @spec PREREQ-EXEC-010
    it "attaches, provisions, and calls the tool endpoint from inside the run, recording the response" do
      contract_with_tool
      allow(MarketplaceEntries::AttachToRun).to receive(:call)
      allow(mcp_provisioner).to receive(:provision) do
        run.update_columns(tool_sidecar_container_ids: [ "tool-1" ],
          tool_sidecar_endpoints: [ { "name" => "analyzer", "hostname" => "paid-tool-analyzer-run1", "port" => 8080, "url" => "http://paid-tool-analyzer-run1:8080" } ])
      end
      stub_native_command
      allow(run).to receive(:execute_in_execution_environment)
        .with(match(/\Acurl -fsS --max-time \d+ http:\/\/paid-tool-analyzer-run1:8080\z/), timeout: anything, stream: false)
        .and_return(execute_result(stdout: "{\"status\":\"ok\"}"))

      runner.call

      expect(MarketplaceEntries::AttachToRun).to have_received(:call)
        .with(hash_including(manual_entry_ids: [ 42 ]))
      tool_step = validation.reload.step_result("tool_sidecar")
      expect(tool_step["status"]).to eq("succeeded")
      expect(tool_step["endpoint"]).to eq("http://paid-tool-analyzer-run1:8080")
      expect(tool_step["stdout"]).to include("status")
      expect(validation.evidence.dig("identity", "tool", "image")).to eq("acme/analyzer:latest")
      expect(validation.evidence["cleanup"]["sidecars"]).to eq("cleaned")
      expect(validation.reload.status).to eq("succeeded")
    end

    it "reports partial when the analyzer succeeds but the sidecar never reports an endpoint" do
      contract_with_tool
      allow(MarketplaceEntries::AttachToRun).to receive(:call)
      allow(mcp_provisioner).to receive(:provision)
      stub_native_command

      runner.call

      expect(validation.reload.status).to eq("partial")
      expect(validation.step_result("native_analyzer")["status"]).to eq("succeeded")
      expect(validation.step_result("tool_sidecar")["status"]).to eq("failed")
      expect(validation.agent_run.reload.status).to eq("completed")
    end
  end

  describe "denied image" do
    it "fails the tool step with the provisioner's typed error and keeps native evidence" do
      contract_with_tool
      allow(MarketplaceEntries::AttachToRun).to receive(:call)
      allow(mcp_provisioner).to receive(:provision)
        .and_raise(Containers::McpProvisioner::Error,
          "Image \"acme/analyzer:latest\" is not in the allowed service images list for this account")
      stub_native_command

      runner.call

      expect(validation.reload.status).to eq("partial")
      expect(validation.step_result("tool_sidecar")["error_message"]).to include("not in the allowed service images list")
    end
  end

  describe "failed execution" do
    it "reports failed with the analyzer exit status when no step succeeds" do
      stub_native_command(execute_result(exit_code: 2, stderr: "boom"))

      runner.call

      expect(validation.reload.status).to eq("failed")
      native_step = validation.step_result("native_analyzer")
      expect(native_step["exit_code"]).to eq(2)
      expect(native_step["stderr"]).to eq("boom")
      expect(validation.agent_run.reload.status).to eq("failed")
    end
  end

  describe "no compatible backend at provision time" do
    # @spec PREREQ-EXEC-011
    it "reports unavailable — distinct from a failed execution — when no environment can be provisioned" do
      allow(run).to receive(:provision_execution_environment)
        .and_raise(Containers::Provision::ProvisionError, "No placement-ready backend could provision the run")

      runner.call

      expect(validation.reload.status).to eq("unavailable")
      expect(validation.last_error).to include("placement-ready backend")
      expect(validation.steps).to be_empty
      expect(validation.agent_run.reload.status).to eq("failed")
    end
  end

  describe "cancellation between steps" do
    # @spec PREREQ-EXEC-013
    it "stops at the checkpoint, preserves collected steps, cleans up, and reports cancelled" do
      allow(git).to receive(:clone_and_checkout_branch) do
        validation.update!(status: "cancelled", finished_at: Time.current)
      end
      stub_native_command

      runner.call

      expect(validation.reload.status).to eq("cancelled")
      expect(validation.step_result("checkout_identity")).to be_present
      expect(run).not_to have_received(:execute_in_execution_environment)
      expect(validation.evidence["cleanup"]["run_container"]).to eq("cleaned")
      expect(validation.agent_run.reload.status).to eq("cancelled")
    end

    it "does nothing for an attempt cancelled while queued" do
      validation.update!(status: "cancelled", finished_at: Time.current)

      runner.call

      expect(run).not_to have_received(:provision_execution_environment)
    end
  end

  describe "checkout failure" do
    it "records the failed step and reports failed without running the analyzer" do
      allow(git).to receive(:clone_and_checkout_branch)
        .and_raise(Containers::GitOperations::CloneError.new("clone failed"))
      stub_native_command

      runner.call

      expect(validation.reload.status).to eq("failed")
      expect(validation.step_result("checkout_identity")["status"]).to eq("failed")
      expect(run).not_to have_received(:execute_in_execution_environment)
    end
  end
end
