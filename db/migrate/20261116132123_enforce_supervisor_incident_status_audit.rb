# frozen_string_literal: true

class EnforceSupervisorIncidentStatusAudit < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        CREATE FUNCTION enforce_supervisor_incident_status_audit() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND
             current_setting('paid.supervisor_incident_status_transition', true) IS DISTINCT FROM 'true' THEN
            RAISE EXCEPTION 'supervisor incident status changes must append a status_changed audit';
          END IF;
          IF TG_OP = 'INSERT' AND
             current_setting('paid.supervisor_incident_status_transition', true) IS DISTINCT FROM 'true' THEN
            RAISE EXCEPTION 'supervisor incident creation must append an opened audit';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        CREATE TRIGGER enforce_supervisor_incident_status_audit
          BEFORE INSERT OR UPDATE ON supervisor_incidents
          FOR EACH ROW EXECUTE FUNCTION enforce_supervisor_incident_status_audit();
      SQL
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS enforce_supervisor_incident_status_audit ON supervisor_incidents;
        DROP FUNCTION IF EXISTS enforce_supervisor_incident_status_audit();
      SQL
    end
  end
end
