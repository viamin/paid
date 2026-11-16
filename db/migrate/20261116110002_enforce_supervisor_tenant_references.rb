# frozen_string_literal: true

class EnforceSupervisorTenantReferences < ActiveRecord::Migration[8.1]
  def up
    create_function :enforce_supervisor_incident_snapshot_tenant, version: 1
    create_function :enforce_supervisor_audit_incident_tenant, version: 1
    create_trigger :enforce_supervisor_incident_snapshot_tenant, version: 1, on: :supervisor_incidents
    create_trigger :enforce_supervisor_audit_incident_tenant, version: 1, on: :supervisor_incident_audits
  end

  def down
    drop_trigger :enforce_supervisor_incident_snapshot_tenant, on: :supervisor_incidents
    drop_trigger :enforce_supervisor_audit_incident_tenant, on: :supervisor_incident_audits
    drop_function :enforce_supervisor_incident_snapshot_tenant
    drop_function :enforce_supervisor_audit_incident_tenant
  end
end
