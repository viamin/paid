# frozen_string_literal: true

class CreatePrerequisiteExecutionValidations < ActiveRecord::Migration[8.1]
  def change
    create_table :prerequisite_execution_validations do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, foreign_key: true
      t.references :agent_run, foreign_key: true
      t.references :initiated_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending"
      t.string :branch, null: false
      t.string :scope_digest, null: false
      t.boolean :stale, null: false, default: false
      t.jsonb :contract, null: false, default: {}
      t.jsonb :capability_snapshot, null: false, default: {}
      t.jsonb :steps, null: false, default: []
      t.jsonb :evidence, null: false, default: {}
      t.text :last_error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :prerequisite_execution_validations,
      [ :issue_id, :created_at ],
      name: "index_prereq_validations_on_issue_created"
    add_index :prerequisite_execution_validations,
      [ :project_id, :created_at ],
      name: "index_prereq_validations_on_project_created"
    add_index :prerequisite_execution_validations,
      :scope_digest,
      name: "index_prereq_validations_on_scope_digest"
    add_index :prerequisite_execution_validations,
      :issue_id,
      where: "status IN ('pending','preparing','running')",
      unique: true,
      name: "index_prereq_validations_one_active_per_issue"
  end
end
