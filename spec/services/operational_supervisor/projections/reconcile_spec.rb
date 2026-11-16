# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::Projections::Reconcile do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:incident) do
    create(:supervisor_incident, account:, status: "open", affected_project_ids: [ project.id ],
      target_ids: { "project_ids" => [ project.id ] })
  end

  around do |example|
    FeatureFlags.enable!(:operational_supervisor, project:)
    example.run
  ensure
    FeatureFlags.disable!(:operational_supervisor, project:)
  end

  it "rebuilds desired projections from durable open incidents without mutating notifications" do # @spec OPERATIONAL-SUPERVISOR-007, OPERATIONAL-SUPERVISOR-009
    stale_projection = { "incident_id" => 99_999, "fingerprint" => "stale" }

    result = described_class.call(incidents: [ incident ], existing: [ stale_projection ])

    expect(result.upsert).to contain_exactly(include("incident_id" => incident.id, "fingerprint" => incident.fingerprint))
    expect(result.remove).to eq([ stale_projection ])
    expect(Notification.count).to eq(0)
  end

  it "removes a projection when its project is disabled" do # @spec OPERATIONAL-SUPERVISOR-008
    existing_projection = { "incident_id" => incident.id, "fingerprint" => incident.fingerprint }
    FeatureFlags.disable!(:operational_supervisor, project:)

    result = described_class.call(incidents: [ incident ], existing: [ existing_projection ])

    expect(result.upsert).to be_empty
    expect(result.remove).to eq([ existing_projection ])
  end
end
