# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::TransitionIncidentStatus do
  let(:incident) { create(:supervisor_incident, status: "open") }
  let(:now) { Time.zone.at(Time.utc(2026, 1, 1, 12, 0, 0)) }

  it "transitions the lifecycle and appends a status_changed audit in one transaction" do # @spec OPERATIONAL-SUPERVISOR-007
    result = described_class.call(incident:, status: "resolved", now:)

    expect(result).not_to be_failure
    expect(result.incident.reload.status).to eq("resolved")
    audit = incident.supervisor_incident_audits.sole
    expect(audit.action).to eq("status_changed")
    expect(audit.evidence).to eq({ "previous_status" => "open", "next_status" => "resolved" })
    expect(audit.occurred_at).to eq(now)
  end

  it "is idempotent when the incident already has the requested status" do # @spec OPERATIONAL-SUPERVISOR-007
    result = nil

    expect { result = described_class.call(incident:, status: "open", now:) }.not_to change(SupervisorIncidentAudit, :count)

    expect(result).not_to be_failure
    expect(result.incident.reload.status).to eq("open")
  end

  it "fails closed on an unknown status without persisting a transition or audit" do # @spec OPERATIONAL-SUPERVISOR-007
    result = described_class.call(incident:, status: "extinguished", now:)

    expect(result).to be_failure
    expect(result.error).to include("is not included")
    expect(result.incident.reload.status).to eq("open")
    expect(result.incident.supervisor_incident_audits.count).to eq(0)
  end
end
