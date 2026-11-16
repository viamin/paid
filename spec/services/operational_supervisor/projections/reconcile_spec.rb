# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::Projections::Reconcile do
  it "rebuilds desired projections from durable open incidents without mutating notifications" do # @spec OPERATIONAL-SUPERVISOR-007, OPERATIONAL-SUPERVISOR-009
    incident = create(:supervisor_incident, status: "open")
    stale_projection = { "incident_id" => 99_999, "fingerprint" => "stale" }

    result = described_class.call(incidents: [ incident ], existing: [ stale_projection ])

    expect(result.upsert).to contain_exactly(include("incident_id" => incident.id, "fingerprint" => incident.fingerprint))
    expect(result.remove).to eq([ stale_projection ])
    expect(Notification.count).to eq(0)
  end
end
