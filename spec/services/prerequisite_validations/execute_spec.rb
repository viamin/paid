# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteValidations::Execute do
  # @spec PARTIAL-CLOSEOUT-030
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project:, base_commit_sha: "abc123", verification_result: {}, external_metadata: { "image" => "paid/agent@sha256:test" }) }
  let(:scheduler) { class_double(Containers::BackendScheduler) }
  let(:flags) { class_double(FeatureFlags) }
  let(:analyzer) { { name: "native-check", version: "1.0", command: [ "native-check", "--version" ] } }

  before do
    allow(scheduler).to receive(:call).with(agent_run:).and_return(Struct.new(:candidate_hosts).new([ "docker" ]))
    allow(agent_run).to receive(:provision_execution_environment)
    allow(agent_run).to receive(:cleanup_execution_environment)
    allow(agent_run).to receive(:reload).and_return(agent_run)
  end

  it "records isolated native and allowlisted sidecar evidence then cleans up" do
    allow(flags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(true)
    agent_run.update!(tool_sidecar_endpoints: [ { "name" => "reporter", "url" => "http://reporter:8080" } ])
    allow(agent_run).to receive(:execute_in_execution_environment).and_return(Struct.new(:stdout, :stderr, :exit_code).new("ok", "", 0))

    result = described_class.call(agent_run:, analyzer:, scheduler:, feature_flags: flags, sidecar_request: { name: "reporter", command: [ "curl", "http://reporter:8080/health" ] })

    expect(result).to be_successful
    expect(agent_run.verification_result.dig("prerequisite_validation", "sidecar", "endpoint", "url")).to eq("http://reporter:8080")
    expect(agent_run.verification_result.dig("prerequisite_validation", "cleanup")).to eq("completed")
    expect(agent_run).to have_received(:cleanup_execution_environment)
  end

  it "reports the exact authorization action instead of provisionally enabling a disabled sidecar flag" do
    allow(flags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(false)

    result = described_class.call(agent_run:, analyzer:, scheduler:, feature_flags: flags, sidecar_request: { name: "reporter", command: [ "curl", "http://reporter" ] })

    expect(result.status).to eq("unavailable")
    expect(result.message).to include("not authorized")
    expect(agent_run).not_to have_received(:provision_execution_environment)
  end

  it "does not confuse an unavailable compatible backend with the control-plane host" do
    allow(scheduler).to receive(:call).with(agent_run:).and_return(Struct.new(:candidate_hosts).new([]))

    result = described_class.call(agent_run:, analyzer:, scheduler:, feature_flags: flags)

    expect(result.status).to eq("unavailable")
    expect(result.evidence.fetch("native")).to be_nil
  end
end
