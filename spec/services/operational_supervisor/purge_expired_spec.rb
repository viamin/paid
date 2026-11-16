# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::PurgeExpired do
  it "removes only records whose recorded retention intervals elapsed" do # @spec OPERATIONAL-SUPERVISOR-003
    expired_snapshot = create(:supervisor_snapshot, captured_at: 2.days.ago, retention_expires_at: 1.second.ago)
    retained_snapshot = create(:supervisor_snapshot)
    expired_incident = create(:supervisor_incident, retention_expires_at: 1.second.ago)
    retained_incident = create(:supervisor_incident)

    result = described_class.call

    expect(result).to eq(described_class::Result.new(1, 1))
    expect(SupervisorSnapshot.exists?(expired_snapshot.id)).to be(false)
    expect(SupervisorSnapshot.exists?(retained_snapshot.id)).to be(true)
    expect(SupervisorIncident.exists?(expired_incident.id)).to be(false)
    expect(SupervisorIncident.exists?(retained_incident.id)).to be(true)
  end

  it "nullifies retained incident snapshot references before deleting expired snapshots" do # @spec OPERATIONAL-SUPERVISOR-003
    expired_snapshot = create(:supervisor_snapshot, captured_at: 2.days.ago, retention_expires_at: 1.second.ago)
    retained_incident = create(:supervisor_incident, account: expired_snapshot.account, supervisor_snapshot: expired_snapshot)

    result = described_class.call

    expect(result).to eq(described_class::Result.new(1, 0))
    expect(SupervisorSnapshot.exists?(expired_snapshot.id)).to be(false)
    expect(retained_incident.reload.supervisor_snapshot).to be_nil
  end
end
