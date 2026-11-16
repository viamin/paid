# frozen_string_literal: true

class AllowSupervisorAuditRetentionPurge < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL
        CREATE OR REPLACE FUNCTION prevent_supervisor_incident_audit_mutation() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND current_setting('paid.supervisor_incident_audit_purge', true) = 'true' THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'supervisor incident audits are append-only';
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        CREATE OR REPLACE FUNCTION prevent_supervisor_incident_audit_mutation() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'supervisor incident audits are append-only';
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end
  end
end
