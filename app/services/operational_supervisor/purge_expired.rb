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
          purge_audits!(expired_incidents)
          nullify_expired_snapshot_references!(expired_snapshots)
          Result.new(expired_snapshots.delete_all, expired_incidents.delete_all)
        end
      end
    end

    private

    def purge_audits!(expired_incidents)
      database = SupervisorIncidentAudit.connection
      database.execute("SET LOCAL paid.supervisor_incident_audit_purge = 'true'")
      SupervisorIncidentAudit.where(supervisor_incident_id: expired_incidents.select(:id)).delete_all
    ensure
      database&.execute("SET LOCAL paid.supervisor_incident_audit_purge = 'false'") unless transaction_failed?(database)
    end

    def transaction_failed?(database)
      database.nil? || database.raw_connection.transaction_status == PG::PQTRANS_INERROR
    end

    def nullify_expired_snapshot_references!(expired_snapshots)
      SupervisorIncident.where(supervisor_snapshot_id: expired_snapshots.select(:id)).update_all(supervisor_snapshot_id: nil)
    end
  end
end
