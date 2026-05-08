# frozen_string_literal: true

class CreateFailureClassifications < ActiveRecord::Migration[8.1]
  def change
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
  end
end
