# frozen_string_literal: true

class CreateFailureClassifications < ActiveRecord::Migration[8.1]
  def up
    create_table :failure_classifications, comment: "Persisted failure classification and chosen recovery action for coordination learning" do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.string :failure_category, limit: 50, null: false, comment: "Classified failure type (e.g. provider_error, timeout, auth_failure)"
      t.string :failure_subcategory, limit: 100, comment: "Optional finer-grained classification"
      t.string :chosen_action, limit: 50, null: false, comment: "Recovery action selected from coordination policy"
      t.string :action_status, limit: 30, null: false, default: "pending", comment: "Lifecycle: pending, executing, completed, skipped"
      t.jsonb :failure_context, null: false, default: {}, comment: "Structured details about the failure (error message, provider, etc.)"
      t.jsonb :action_params, null: false, default: {}, comment: "Parameters passed to the chosen recovery action"
      t.jsonb :action_result, null: false, default: {}, comment: "Outcome of executing the recovery action"
      t.string :parent_workflow_id, limit: 255, comment: "Workflow context for coordinated recovery"
      t.datetime :executed_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :failure_classifications, :failure_category
    add_index :failure_classifications, :chosen_action
    add_index :failure_classifications, :action_status
    add_index :failure_classifications, [ :project_id, :created_at ], name: "idx_failure_classifications_project_created"
    add_index :failure_classifications, :parent_workflow_id

    safety_assured do
      execute <<~SQL
        ALTER TABLE failure_classifications ENABLE ROW LEVEL SECURITY;
        ALTER TABLE failure_classifications FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON failure_classifications
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = failure_classifications.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = failure_classifications.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          ;
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON failure_classifications"
      execute "ALTER TABLE failure_classifications NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE failure_classifications DISABLE ROW LEVEL SECURITY"
    end

    drop_table :failure_classifications
  end
end
