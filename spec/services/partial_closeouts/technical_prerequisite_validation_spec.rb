# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::TechnicalPrerequisiteValidation do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project:, base_commit_sha: "abc123") }
  let(:plan) { instance_double(PartialCloseouts::TechnicalPrerequisitePlan::Result, ready?: true, host: "remote-docker", evidence: { "candidate_hosts" => [ "remote-docker" ] }) }
  let(:runner) { instance_double(ExecutionRunners::LocalDockerRunner) }

  before do
    allow(PartialCloseouts::TechnicalPrerequisitePlan).to receive(:call).and_return(plan)
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(
      Containers::Provision::Result.success(stdout: "analyzer output", stderr: "", exit_code: 0)
    )
    allow(agent_run).to receive(:cleanup_execution_environment)
    allow(ExecutionRunners).to receive(:resolve_for).with(agent_run).and_return(runner)
    allow(runner).to receive(:provision_mcp_servers).with(agent_run:, network: anything).and_return({ stdio_servers: [], url_servers: [] })
    allow(runner).to receive(:cleanup_mcp_servers).with(agent_run:)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "runs the selected analyzer only in the prepared execution environment and persists result plus cleanup evidence" do
    result = described_class.call(agent_run:, analyzer: "native", command: [ "bin/analyze" ])

    expect(result.status).to eq(:succeeded)
    expect(agent_run).to have_received(:execute_in_execution_environment).with([ "bin/analyze" ], timeout: nil, stream: false)
    evidence = agent_run.reload.external_metadata.fetch("technical_prerequisite_validation")
    expect(evidence).to include("status" => "succeeded", "checkout" => "abc123")
    expect(evidence.fetch("result")).to include("stdout" => "analyzer output")
    expect(evidence.fetch("cleanup")).to include("environment" => "completed", "tool_sidecars" => "completed")
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "records an unavailable plan without provisioning or retrying the same host" do
    unavailable = instance_double(PartialCloseouts::TechnicalPrerequisitePlan::Result,
      ready?: false, action: "Configure a compatible execution host", evidence: { "candidate_hosts" => [] })
    allow(PartialCloseouts::TechnicalPrerequisitePlan).to receive(:call).and_return(unavailable)

    result = described_class.call(agent_run:, analyzer: "native", command: [ "bin/analyze" ])

    expect(result.status).to eq(:unavailable)
    expect(agent_run).not_to have_received(:provision_execution_environment)
    expect(agent_run.reload.external_metadata.dig("technical_prerequisite_validation", "action")).to include("compatible execution host")
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "distinguishes cancellation from a successful validation and still cleans up" do
    allow(agent_run).to receive(:execute_in_execution_environment).and_raise(Interrupt, "cancelled")

    result = described_class.call(agent_run:, analyzer: "native", command: [ "bin/analyze" ])

    expect(result.status).to eq(:cancelled)
    expect(runner).to have_received(:cleanup_mcp_servers).with(agent_run:)
    expect(agent_run).to have_received(:cleanup_execution_environment)
  end
end
