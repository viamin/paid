# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::ValidationPreflight do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project: project) }

  # @spec PARTIAL-CLOSEOUT-030
  it "uses compatible execution hosts even when the investigation host has no Docker" do
    scheduler = instance_double(Containers::BackendScheduler::Result,
      candidate_hosts: [ "remote-docker" ], compatibility_failures: {}, health_failures: {})
    allow(Containers::BackendScheduler).to receive(:call).with(agent_run: agent_run).and_return(scheduler)

    result = described_class.call(agent_run: agent_run)

    expect(result.ready?).to be(true)
    expect(result.compatible_hosts).to eq([ "remote-docker" ])
    expect(result.setup_actions).to be_empty
  end

  it "reports the rollout authorization separately from execution capability" do
    scheduler = instance_double(Containers::BackendScheduler::Result,
      candidate_hosts: [ "remote-docker" ], compatibility_failures: {}, health_failures: {})
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler)
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: project).and_return(false)
    allow(agent_run).to receive(:tool_sidecar_snapshot)
      .and_return([ { "name" => "analyzer", "image" => "registry/analyzer@sha256:abc" } ])

    result = described_class.call(agent_run: agent_run)

    expect(result.ready?).to be(false)
    expect(result.setup_actions).to include(hash_including(code: "marketplace_tool_sidecars_disabled"))
    expect(result.compatible_hosts).to eq([ "remote-docker" ])
  end

  it "returns the scheduler's exact capability failures when no backend is compatible" do
    scheduler = instance_double(Containers::BackendScheduler::Result,
      candidate_hosts: [], compatibility_failures: { "local" => "Docker is unavailable" }, health_failures: {})
    allow(Containers::BackendScheduler).to receive(:call).and_return(scheduler)

    result = described_class.call(agent_run: agent_run)

    expect(result.ready?).to be(false)
    expect(result.setup_actions).to include(hash_including(code: "no_compatible_execution_backend"))
  end
end
