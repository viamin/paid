# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::TechnicalPrerequisiteReadiness do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :queued, project:) }
  let(:scheduler) { class_double(Containers::BackendScheduler) }

  def schedule(hosts: [], requirements_error: nil, compatibility_failures: {}, health_failures: {})
    Containers::BackendScheduler::Result.new(
      candidate_hosts: hosts,
      requirements_error: requirements_error,
      compatibility_failures: compatibility_failures,
      health_failures: health_failures
    )
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "uses the configured execution scheduler rather than local Docker availability" do
    allow(scheduler).to receive(:call).with(agent_run:).and_return(schedule(hosts: [ "remote-docker" ]))

    result = described_class.call(agent_run:, scheduler:)

    expect(result).to have_attributes(status: :ready, action: :start_validation, candidate_hosts: [ "remote-docker" ])
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "names the required rollout authorization when a tool sidecar is requested while its guard is off" do
    FeatureFlags.disable!(:marketplace_tool_sidecars, project:)
    allow(scheduler).to receive(:call)

    result = described_class.call(agent_run:, requires_tool_sidecar: true, scheduler:)

    expect(result).to have_attributes(status: :authorization_required, action: :enable_tool_sidecar_pilot)
    expect(result.message).to include("marketplace_tool_sidecars")
    expect(scheduler).not_to have_received(:call)
  end

  # @spec PARTIAL-CLOSEOUT-031
  it "reports a lack of compatible backends with scheduler evidence" do
    allow(scheduler).to receive(:call).with(agent_run:).and_return(
      schedule(compatibility_failures: { "local" => "host path mounts are unavailable" })
    )

    result = described_class.call(agent_run:, scheduler:)

    expect(result).to have_attributes(status: :unavailable, action: :configure_compatible_backend)
    expect(result.failures).to include("local" => "host path mounts are unavailable")
  end
end
