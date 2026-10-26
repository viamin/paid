# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ExecutionPrerequisiteReadiness do
  # @spec PARTIAL-CLOSEOUT-030
  it "uses compatible Paid backends instead of the control-plane Docker socket" do
    project = build_stubbed(:project)
    run = build_stubbed(:agent_run, project:, tool_sidecar_snapshot: [])
    placement = Containers::BackendScheduler::Result.new(
      candidate_hosts: [ "remote-docker" ], compatibility_failures: {}, health_failures: {}
    )
    scheduler = class_double(Containers::BackendScheduler, call: placement)

    result = described_class.call(agent_run: run, scheduler:)

    expect(result).to have_attributes(status: "ready", hosts: [ "remote-docker" ], actions: [])
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "requests explicit sidecar rollout authorization without enabling the flag" do
    project = build_stubbed(:project)
    run = build_stubbed(:agent_run, project:, tool_sidecar_snapshot: [ { "name" => "scanner" } ])
    placement = Containers::BackendScheduler::Result.new(
      candidate_hosts: [ "remote-docker" ], compatibility_failures: {}, health_failures: {}
    )
    scheduler = class_double(Containers::BackendScheduler, call: placement)
    flags = class_double(FeatureFlags, enabled?: false)

    result = described_class.call(agent_run: run, scheduler:, flags:)

    expect(result.status).to eq("authorization_required")
    expect(result.actions.first).to include("marketplace_tool_sidecars")
  end
end
