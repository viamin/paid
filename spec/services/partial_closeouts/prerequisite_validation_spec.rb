# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::PrerequisiteValidation do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:run) { create(:agent_run, :queued, project:, issue:, tool_sidecar_snapshot: [ { "name" => "analyzer" } ]) }
  let(:readiness) { { "isolated" => { host: "isolated", healthy: true } } }
  let(:host_readiness) { class_double(Containers::HostReadiness, call: readiness) }
  let(:feature_flags) { class_double(FeatureFlags, enabled?: true) }

  # @spec PARTIAL-CLOSEOUT-030
  it "records an explicit rollout setup action without provisioning when the tool flag is off" do
    allow(feature_flags).to receive(:enabled?).with(:marketplace_tool_sidecars, project:).and_return(false)

    result = described_class.call(agent_run: run, host_readiness:, feature_flags:)

    expect(result.status).to eq("unavailable")
    expect(run.reload.reconciliation.dig("technical_prerequisite_validation", "code")).to eq("tool_rollout_authorization_required")
    expect(run.reconciliation.dig("technical_prerequisite_validation", "setup_action")).to include("does not enable flags")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "records isolated command and cleanup evidence rather than using the host" do
    run.update!(tool_sidecar_endpoints: [ { "url" => "http://paid-tool-run:8080" } ])
    success = instance_double(Containers::Provision::Result, success?: true, :[] => nil)
    allow(run).to receive(:provision_execution_environment)
    allow(run).to receive(:execute_in_execution_environment).and_return(success)
    allow(run).to receive(:cleanup_execution_environment)

    result = described_class.call(agent_run: run, host_readiness:, feature_flags:)

    expect(result.status).to eq("successful")
    expect(run).to have_received(:provision_execution_environment)
    expect(run).to have_received(:execute_in_execution_environment).twice
    expect(run.reload.reconciliation.dig("technical_prerequisite_validation", "cleanup", "succeeded")).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "keeps no compatible backend distinct from a failed command" do
    unavailable_readiness = { "local" => { host: "local", healthy: false } }

    result = described_class.call(agent_run: run, host_readiness: class_double(Containers::HostReadiness, call: unavailable_readiness), feature_flags:)

    expect(result.status).to eq("unavailable")
    expect(result.evidence[:code]).to eq("compatible_execution_backend_unavailable")
  end
end
