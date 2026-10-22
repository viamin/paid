# frozen_string_literal: true

# @spec FEATURE-APPROVAL-024
class AddRunAdmissionProvenanceAndFeatureIntentIssueDependencies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :agent_runs, :approved_design_revision, :string,
      comment: "Approved feature design revision that admitted this implementation run." unless column_exists?(:agent_runs, :approved_design_revision)
    add_index :agent_runs, :approved_design_revision, algorithm: :concurrently unless index_exists?(:agent_runs, :approved_design_revision)

    unless table_exists?(:feature_intent_issue_dependencies)
      create_table :feature_intent_issue_dependencies,
        comment: "Snapshot of dependency edges between issues in one approved feature tree." do |t|
        t.references :feature_intent_issue, null: false, foreign_key: { on_delete: :cascade }
        t.references :depends_on_feature_intent_issue, null: false,
          foreign_key: { to_table: :feature_intent_issues, on_delete: :cascade }

        t.timestamps
      end
    end
    unless index_exists?(:feature_intent_issue_dependencies,
      %i[feature_intent_issue_id depends_on_feature_intent_issue_id],
      name: "idx_feature_intent_issue_dependencies_unique")
      add_index :feature_intent_issue_dependencies,
        %i[feature_intent_issue_id depends_on_feature_intent_issue_id], unique: true,
        name: "idx_feature_intent_issue_dependencies_unique"
    end

    safety_assured do
      execute <<~SQL
        ALTER TABLE feature_intent_issue_dependencies ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_issue_dependencies FORCE ROW LEVEL SECURITY;
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = current_schema()
              AND tablename = 'feature_intent_issue_dependencies'
              AND policyname = 'tenant_isolation'
          ) THEN
            CREATE POLICY tenant_isolation ON feature_intent_issue_dependencies
              AS PERMISSIVE FOR ALL
              USING (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1 FROM feature_intent_issues
                  INNER JOIN feature_intents ON feature_intents.id = feature_intent_issues.feature_intent_id
                  INNER JOIN projects ON projects.id = feature_intents.project_id
                  WHERE feature_intent_issues.id = feature_intent_issue_dependencies.feature_intent_issue_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              WITH CHECK (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1 FROM feature_intent_issues
                  INNER JOIN feature_intents ON feature_intents.id = feature_intent_issues.feature_intent_id
                  INNER JOIN projects ON projects.id = feature_intents.project_id
                  WHERE feature_intent_issues.id = feature_intent_issue_dependencies.feature_intent_issue_id
                    AND projects.account_id = paid_current_account_id()
                )
              );
          END IF;
        END
        $$;
      SQL
    end
  end

  def down
    if table_exists?(:feature_intent_issue_dependencies)
      safety_assured do
        execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_issue_dependencies"
        execute "ALTER TABLE feature_intent_issue_dependencies NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE feature_intent_issue_dependencies DISABLE ROW LEVEL SECURITY"
      end
      drop_table :feature_intent_issue_dependencies
    end
    remove_index :agent_runs, :approved_design_revision if index_exists?(:agent_runs, :approved_design_revision)
    remove_column :agent_runs, :approved_design_revision if column_exists?(:agent_runs, :approved_design_revision)
  end
end
