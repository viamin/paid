# frozen_string_literal: true

module OperationalSupervisor
  class PurgeExpired
    Result = Data.define(:snapshots, :incidents)

    def self.call(...) = new(...).call

    # @spec OPERATIONAL-SUPERVISOR-003
    def call
      TenantContext.with_system_access do
        SupervisorIncident.transaction do
          expired_incidents = SupervisorIncident.expired
          expired_snapshots = SupervisorSnapshot.expired
          enable_audit_purge!
          SupervisorIncidentAudit.where(supervisor_incident_id: expired_incidents.select(:id)).delete_all
          nullify_expired_snapshot_references!(expired_snapshots)
          Result.new(expired_snapshots.delete_all, expired_incidents.delete_all)
        end
      end
    end

    private

    def enable_audit_purge!
      SupervisorIncidentAudit.connection.execute("SET LOCAL paid.supervisor_incident_audit_purge = 'true'")
    end

    def nullify_expired_snapshot_references!(expired_snapshots)
      SupervisorIncident.where(supervisor_snapshot_id: expired_snapshots.select(:id)).update_all(supervisor_snapshot_id: nil)
    end
  end
end
