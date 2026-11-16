class CreateMaintenanceReportsAndFindings < ActiveRecord::Migration[8.1]
  def up
    create_table :maintenance_reports do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :outcome, null: false, limit: 32
      t.text :resolved_scope
      t.jsonb :exclusions, null: false, default: []
      t.jsonb :completed_checks, null: false, default: []
      t.jsonb :incomplete_checks, null: false, default: []
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end

    create_table :maintenance_findings do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :recipe_key, null: false, default: "custom", limit: 100
      t.string :identity_digest, null: false, limit: 64
      t.string :category, null: false, limit: 100
      t.text :claim, null: false
      t.jsonb :symbols, null: false, default: []
      t.jsonb :locations, null: false, default: []
      t.string :status, null: false, default: "open", limit: 32
      t.text :dismissal_reason
      t.boolean :reassessment_required, null: false, default: false
      t.string :supporting_evidence_digest, limit: 64
      t.timestamps
    end
    add_index :maintenance_findings, [ :project_id, :recipe_key, :identity_digest ], unique: true,
      name: "index_maintenance_findings_on_recurring_identity"

    create_table :maintenance_finding_occurrences do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :maintenance_report, null: false, foreign_key: { on_delete: :cascade }
      t.references :maintenance_finding, null: false, foreign_key: { on_delete: :cascade }
      t.string :category, null: false, limit: 100
      t.text :claim, null: false
      t.jsonb :symbols, null: false, default: []
      t.jsonb :locations, null: false, default: []
      t.jsonb :supporting_evidence, null: false, default: []
      t.jsonb :contrary_evidence, null: false, default: []
      t.jsonb :analyzer_provenance, null: false, default: {}
      t.decimal :raw_tool_confidence, precision: 5, scale: 4
      t.string :agent_assessment, limit: 32
      t.text :proposed_action
      t.text :validation_plan
      t.string :verification_disposition, null: false, limit: 32
      t.string :observed_status, null: false, limit: 32
      t.timestamps
    end
    add_index :maintenance_finding_occurrences, [ :maintenance_report_id, :maintenance_finding_id ], unique: true,
      name: "index_maintenance_occurrences_on_report_and_finding"

    enable_tenant_rls!(:maintenance_reports)
    enable_tenant_rls!(:maintenance_findings)
    enable_tenant_rls!(:maintenance_finding_occurrences)
  end

  def down
    %i[maintenance_finding_occurrences maintenance_findings maintenance_reports].each do |table|
      safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}" }
      safety_assured { execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY" }
      safety_assured { execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY" }
      drop_table table
    end
  end

  private

  def enable_tenant_rls!(table)
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
