# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceRuns::TechnicalPrerequisiteValidation do
  # @spec TECHNICAL-PREREQUISITE-001
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:run) { create(:agent_run, project:, base_commit_sha: "a" * 40) }
  let(:backend) { create(:docker_host, account:, readiness_status: "ready", image_status: "ready", required_network_status: "ready", required_infra_network_status: "ready") }
  let(:result) { Containers::Provision::Result.success(stdout: "native", stderr: "", exit_code: 0) }

  before do
    allow(DockerHost).to receive(:placement_ready_for_restricted_agent_runs).and_return(DockerHost.where(id: backend))
    allow(run).to receive(:provision_execution_environment)
    allow(run).to receive(:cleanup_execution_environment)
    allow(run).to receive(:execute_in_execution_environment).and_return(result)
  end

  it "records native execution evidence and cleans up through the isolated run" do
    outcome = described_class.call(agent_run: run, command: [ "native-analyzer", "--version" ])

    expect(outcome).to be_success
    expect(run.reload.verification_result.dig("technical_prerequisite_validation", "stdout")).to eq("native")
    expect(run).to have_received(:execute_in_execution_environment).with([ "native-analyzer", "--version" ], stream: false)
    expect(run).to have_received(:cleanup_execution_environment)
  end

  it "records the exact rollout authorization action instead of provisioning a disabled tool" do
    outcome = described_class.call(agent_run: run, command: [ "native-analyzer" ], requires_tool_sidecar: true)

    expect(outcome.status).to eq("unavailable")
    expect(outcome.message).to include("marketplace_tool_sidecars pilot")
    expect(run).not_to have_received(:provision_execution_environment)
  end

  it "uses compatible backend readiness rather than local Docker availability" do
    outcome = described_class.call(agent_run: run, command: [ "native-analyzer" ])

    expect(outcome).to be_success
    expect(run.container_host).to eq(backend.identifier)
  end

  it "keeps a cancelled validation distinct from an unavailable backend" do
    run.update!(status: "cancelled")

    outcome = described_class.call(agent_run: run, command: [ "native-analyzer" ])

    expect(outcome.status).to eq("unavailable")
    expect(run.reload.verification_result.dig("technical_prerequisite_validation", "unavailable_reason")).to eq("cancelled")
    expect(run).not_to have_received(:provision_execution_environment)
  end

  it "records a failed isolated command with its exit status" do
    allow(run).to receive(:execute_in_execution_environment).and_return(
      Containers::Provision::Result.failure(error: "failed", stdout: "partial", stderr: "failed", exit_code: 7)
    )

    outcome = described_class.call(agent_run: run, command: [ "native-analyzer" ])

    expect(outcome.status).to eq("failed")
    expect(run.reload.verification_result.dig("technical_prerequisite_validation", "exit_code")).to eq(7)
  end
end
