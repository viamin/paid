# frozen_string_literal: true

require "rails_helper"

RSpec.describe SupervisorIncident do
  it "deduplicates Rails-derived fingerprints inside an account" do # @spec OPERATIONAL-SUPERVISOR-007
    incident = create(:supervisor_incident)

    duplicate = build(:supervisor_incident, account: incident.account, fingerprint: incident.fingerprint)

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:fingerprint]).to include("has already been taken")
  end

  it "rejects unsafe evidence and targets from another account" do # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-004
    other_project = create(:project)
    incident = build(:supervisor_incident, affected_project_ids: [ other_project.id ], evidence: { "raw_output" => "model response" })

    expect(incident).to be_invalid
    expect(incident.errors[:evidence]).to include("contains unsupported or unsafe fields")
    expect(incident.errors[:affected_project_ids]).to include("must belong to the incident account")
  end

  it "rejects unrecognized incident evidence" do # @spec OPERATIONAL-SUPERVISOR-001
    incident = build(:supervisor_incident, evidence: { "issue_title" => "customer-authored text" })

    expect(incident).to be_invalid
    expect(incident.errors[:evidence]).to include("contains unsupported or unsafe fields")
  end

  it "rejects unrecognized audit evidence" do # @spec OPERATIONAL-SUPERVISOR-001
    audit = build(:supervisor_incident_audit, evidence: { "issue_title" => "customer-authored text" })

    expect(audit).to be_invalid
    expect(audit.errors[:evidence]).to include("contains unsupported or unsafe fields")
  end

  it "keeps its audit trail append-only in the database" do # @spec OPERATIONAL-SUPERVISOR-007
    audit = create(:supervisor_incident_audit)

    expect { within_savepoint { SupervisorIncidentAudit.where(id: audit.id).update_all(action: "observed") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { within_savepoint { SupervisorIncidentAudit.where(id: audit.id).delete_all } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "rejects cross-tenant references even when application validations are bypassed" do # @spec OPERATIONAL-SUPERVISOR-004
    account = create(:account)
    other_snapshot = create(:supervisor_snapshot)

    expect do
      within_savepoint do
        described_class.insert_all!([ attributes_for(:supervisor_incident).merge(account_id: account.id, supervisor_snapshot_id: other_snapshot.id) ])
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /must belong to the incident account/)
  end

  it "rejects a bare status write that would skip the audit trail" do # @spec OPERATIONAL-SUPERVISOR-007
    incident = create(:supervisor_incident, status: "open")

    expect { incident.update!(status: "resolved") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(incident.errors[:status]).to include("transitions must be recorded by OperationalSupervisor::TransitionIncidentStatus")
    expect(incident.reload.status).to eq("open")
    expect(incident.supervisor_incident_audits.count).to eq(0)
  end

  it "blocks unaudited status transitions even when application validations are bypassed" do # @spec OPERATIONAL-SUPERVISOR-007
    incident = create(:supervisor_incident, status: "open")

    expect do
      within_savepoint { described_class.where(id: incident.id).update_all(status: "resolved") }
    end.to raise_error(ActiveRecord::StatementInvalid, /status_changed audit/)
    expect do
      within_savepoint do
        described_class.insert_all!([ attributes_for(:supervisor_incident).merge(account_id: incident.account_id, status: "resolved") ])
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /status_changed audit/)
    expect(incident.reload.status).to eq("open")
  end

  def within_savepoint(&)
    ActiveRecord::Base.transaction(requires_new: true, &)
  end
end
