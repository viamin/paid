# frozen_string_literal: true

module OperationalSupervisor
  class PurgeExpired
    Result = Data.define(:snapshots, :incidents)

    def self.call(...) = new(...).call

    def call
      SupervisorIncident.transaction do
        expired_incidents = SupervisorIncident.expired
        enable_audit_purge!
        SupervisorIncidentAudit.where(supervisor_incident_id: expired_incidents.select(:id)).delete_all
        Result.new(SupervisorSnapshot.expired.delete_all, expired_incidents.delete_all)
      end
    end

    private

    def enable_audit_purge!
      SupervisorIncidentAudit.connection.execute("SET LOCAL paid.supervisor_incident_audit_purge = 'true'")
    end
  end
end
