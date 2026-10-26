# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::TechnicalPrerequisitePlan do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project:) }
  let(:scheduler) { instance_double(Containers::BackendScheduler::Result) }

  before do
    allow(Containers::BackendScheduler).to receive(:call).with(agent_run:).and_return(scheduler)
    allow(scheduler).to receive_messages(
      candidate_hosts: [ "remote-docker" ],
      requirements_error: nil,
      compatibility_failures: { "local" => "local socket unavailable" },
      health_failures: {}
    )
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "selects a compatible backend even when the investigation host lacks Docker" do
    result = described_class.call(agent_run:, tool_name: "native-analyzer")

    expect(result.ready?).to be(true)
    expect(result.host).to eq("remote-docker")
    expect(result.evidence).to include("compatibility_failures" => { "local" => "local socket unavailable" })
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "names the rollout authorization required before a selected tool sidecar can run" do
    result = described_class.call(agent_run:, tool_name: "sidecar", tool_image: "registry.test/tool:1")

    expect(result.ready?).to be(false)
    expect(result.status).to eq(:authorization_required)
    expect(result.action).to include("marketplace_tool_sidecars")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "reports no compatible backend with the scheduler's durable diagnostics" do
    allow(scheduler).to receive_messages(candidate_hosts: [], health_failures: { "remote-docker" => "unreachable" })

    result = described_class.call(agent_run:, tool_name: "native-analyzer")

    expect(result.status).to eq(:unavailable)
    expect(result.action).to include("compatible execution host")
    expect(result.evidence).to include("health_failures" => { "remote-docker" => "unreachable" })
  end
end
