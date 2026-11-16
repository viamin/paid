# frozen_string_literal: true

class CreateSupervisorPersistence < ActiveRecord::Migration[8.1]
  def up
    create_table :supervisor_snapshots do |t|
      t.references :account, null: false, foreign_key: true
      t.jsonb :digest, null: false, default: {}
      t.bigint :included_project_ids, array: true, null: false, default: []
      t.jsonb :metric_provenance, null: false, default: {}
      t.datetime :captured_at, null: false
      t.datetime :retention_expires_at, null: false
      t.timestamps
    end

    create_table :supervisor_incidents do |t|
      t.references :account, null: false, foreign_key: true
      t.references :supervisor_snapshot, foreign_key: true
      t.string :fingerprint, null: false
      t.string :category, null: false
      t.string :severity, null: false
      t.string :status, null: false, default: "open"
      t.bigint :affected_project_ids, array: true, null: false, default: []
      t.jsonb :target_ids, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.string :model_identifier, null: false
      t.string :prompt_identifier, null: false
      t.string :policy_identifier, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :occurrence_count, null: false, default: 1
      t.datetime :retention_expires_at, null: false
      t.timestamps
    end

    create_table :supervisor_incident_audits do |t|
      t.references :account, null: false, foreign_key: true
      t.references :supervisor_incident, null: false, foreign_key: true
      t.string :action, null: false
      t.jsonb :evidence, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :supervisor_snapshots, [ :account_id, :retention_expires_at ]
    add_index :supervisor_incidents, [ :account_id, :fingerprint ], unique: true, name: "index_supervisor_incidents_on_account_and_fingerprint"
    add_index :supervisor_incidents, [ :account_id, :status ]
    add_index :supervisor_incidents, [ :account_id, :retention_expires_at ]
    add_index :supervisor_incident_audits, [ :supervisor_incident_id, :occurred_at ]

    enable_tenant_rls
    create_append_only_audit_trigger
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS prevent_supervisor_incident_audit_update ON supervisor_incident_audits;
        DROP FUNCTION IF EXISTS prevent_supervisor_incident_audit_mutation();
      SQL
    end
    drop_table :supervisor_incident_audits
    drop_table :supervisor_incidents
    drop_table :supervisor_snapshots
  end

  private

  def enable_tenant_rls
    %w[supervisor_snapshots supervisor_incidents supervisor_incident_audits].each do |table|
      safety_assured do
        execute <<~SQL
          ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
          ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
          CREATE POLICY tenant_isolation ON #{table}
            USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
            WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
        SQL
      end
    end
  end

  def create_append_only_audit_trigger
    safety_assured do
      execute <<~SQL
        CREATE FUNCTION prevent_supervisor_incident_audit_mutation() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' AND current_setting('paid.supervisor_incident_audit_purge', true) = 'true' THEN
            RETURN OLD;
          END IF;
          RAISE EXCEPTION 'supervisor incident audits are append-only';
        END;
        $$ LANGUAGE plpgsql;
        CREATE TRIGGER prevent_supervisor_incident_audit_update
          BEFORE UPDATE OR DELETE ON supervisor_incident_audits
          FOR EACH ROW EXECUTE FUNCTION prevent_supervisor_incident_audit_mutation();
      SQL
    end
  end
end
