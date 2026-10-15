# frozen_string_literal: true

class CreateDesignArtifactFindings < ActiveRecord::Migration[8.1]
  def up
    create_table :design_artifact_findings, comment: "Durable issue-tree traceability gaps found while reconciling repository design artifacts." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :fingerprint, null: false, limit: 64, comment: "Stable reconciliation finding identity for one artifact, revision, and state."
      t.string :artifact_path, null: false, limit: 2048
      t.string :revision, null: false, limit: 255
      t.string :state, null: false, limit: 32, comment: "missing_tree, partial_tree, stale_metadata, deferred, or unverifiable."
      t.jsonb :evidence, null: false, default: []
      t.datetime :covered_at, null: false, comment: "When the GitHub issue coverage used for this finding was read."
      t.string :status, null: false, default: "open", limit: 16
      t.datetime :resolved_at
      t.timestamps null: false
    end

    add_index :design_artifact_findings, [ :project_id, :fingerprint ], unique: true
    add_index :design_artifact_findings, [ :project_id, :status ]
    add_check_constraint :design_artifact_findings,
      "state IN ('missing_tree', 'partial_tree', 'stale_metadata', 'deferred', 'unverifiable')",
      name: "chk_design_artifact_findings_state"
    add_check_constraint :design_artifact_findings, "status IN ('open', 'resolved')",
      name: "chk_design_artifact_findings_status"

    safety_assured do
      execute <<~SQL
        ALTER TABLE design_artifact_findings ENABLE ROW LEVEL SECURITY;
        ALTER TABLE design_artifact_findings FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON design_artifact_findings
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (design_artifact_findings.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (design_artifact_findings.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON design_artifact_findings" }
    safety_assured { execute "ALTER TABLE design_artifact_findings NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE design_artifact_findings DISABLE ROW LEVEL SECURITY" }
    drop_table :design_artifact_findings
  end
end
