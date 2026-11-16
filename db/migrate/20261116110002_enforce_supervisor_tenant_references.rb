# frozen_string_literal: true

class EnforceSupervisorTenantReferences < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        CREATE FUNCTION enforce_supervisor_incident_snapshot_tenant() RETURNS trigger AS $$
        BEGIN
          IF NEW.supervisor_snapshot_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM supervisor_snapshots WHERE id = NEW.supervisor_snapshot_id AND account_id = NEW.account_id
          ) THEN
            RAISE EXCEPTION 'supervisor_snapshot_id must belong to the incident account';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        CREATE FUNCTION enforce_supervisor_audit_incident_tenant() RETURNS trigger AS $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM supervisor_incidents WHERE id = NEW.supervisor_incident_id AND account_id = NEW.account_id
          ) THEN
            RAISE EXCEPTION 'supervisor_incident_id must belong to the audit account';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        CREATE TRIGGER enforce_supervisor_incident_snapshot_tenant
          BEFORE INSERT OR UPDATE ON supervisor_incidents
          FOR EACH ROW EXECUTE FUNCTION enforce_supervisor_incident_snapshot_tenant();
        CREATE TRIGGER enforce_supervisor_audit_incident_tenant
          BEFORE INSERT OR UPDATE ON supervisor_incident_audits
          FOR EACH ROW EXECUTE FUNCTION enforce_supervisor_audit_incident_tenant();
      SQL
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS enforce_supervisor_incident_snapshot_tenant ON supervisor_incidents;
        DROP TRIGGER IF EXISTS enforce_supervisor_audit_incident_tenant ON supervisor_incident_audits;
        DROP FUNCTION IF EXISTS enforce_supervisor_incident_snapshot_tenant();
        DROP FUNCTION IF EXISTS enforce_supervisor_audit_incident_tenant();
      SQL
    end
  end
end
