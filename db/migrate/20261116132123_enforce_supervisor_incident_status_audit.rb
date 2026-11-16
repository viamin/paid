# frozen_string_literal: true

class EnforceSupervisorIncidentStatusAudit < ActiveRecord::Migration[8.1]
  def up
    create_function :enforce_supervisor_incident_status_audit, version: 1
    create_trigger :enforce_supervisor_incident_status_audit, version: 1, on: :supervisor_incidents
  end

  def down
    drop_trigger :enforce_supervisor_incident_status_audit, on: :supervisor_incidents
    drop_function :enforce_supervisor_incident_status_audit
  end
end
