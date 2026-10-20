# frozen_string_literal: true

class CreateDesignArtifactAssociations < ActiveRecord::Migration[8.1]
  def up
    create_table :design_artifact_associations, comment: "Evidence-backed local reconciliation links between a design artifact revision and synchronized GitHub work." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :artifact_path, null: false, limit: 2048
      t.string :artifact_revision, null: false, limit: 255
      t.string :issue_identity, null: false, limit: 512, comment: "Repository-qualified synchronized issue identity."
      t.string :issue_revision, limit: 255, comment: "Synchronized issue revision assessed for this association."
      t.string :provenance, null: false, limit: 255, comment: "Structural evidence that established the local association."
      t.timestamps null: false
    end

    add_index :design_artifact_associations,
      [ :project_id, :artifact_path, :artifact_revision, :issue_identity ],
      unique: true, name: "idx_design_artifact_associations_identity"

    safety_assured do
      execute <<~SQL
        ALTER TABLE design_artifact_associations ENABLE ROW LEVEL SECURITY;
        ALTER TABLE design_artifact_associations FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON design_artifact_associations
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (design_artifact_associations.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (design_artifact_associations.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON design_artifact_associations" }
    safety_assured { execute "ALTER TABLE design_artifact_associations NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE design_artifact_associations DISABLE ROW LEVEL SECURITY" }
    drop_table :design_artifact_associations
  end
end
