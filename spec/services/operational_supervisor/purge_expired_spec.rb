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

  it "purges expired records across accounts when no tenant context is present" do # @spec OPERATIONAL-SUPERVISOR-003
    expired_incident = create(:supervisor_incident, retention_expires_at: 1.second.ago)
    expired_audit = create(:supervisor_incident_audit, supervisor_incident: expired_incident)
    TenantContext.clear!

    result = described_class.call

    expect(result).to eq(described_class::Result.new(0, 1))
    TenantContext.with_system_access do
      expect(SupervisorIncident.exists?(expired_incident.id)).to be(false)
      expect(SupervisorIncidentAudit.exists?(expired_audit.id)).to be(false)
    end
  ensure
    TenantContext.apply_system_access!
  end

  it "restores audit purge authorization before returning inside an outer transaction" do # @spec OPERATIONAL-SUPERVISOR-003, OPERATIONAL-SUPERVISOR-007
    retained_audit = create(:supervisor_incident_audit)

    SupervisorIncident.transaction do
      described_class.call

      expect do
        SupervisorIncidentAudit.transaction(requires_new: true) do
          SupervisorIncidentAudit.where(id: retained_audit.id).delete_all
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end
end
