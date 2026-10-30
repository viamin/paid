# frozen_string_literal: true

class CreateAgentPlanningHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_planning_holds do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :agent_run, foreign_key: true
      t.string :label, null: false, default: "planning"
      t.string :status, null: false, default: "needs_review"
      t.string :task_kind
      t.text :reason
      t.jsonb :release_condition, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.boolean :operator_override, null: false, default: false
      t.datetime :reconciled_at
      t.text :last_error
      t.timestamps
    end

    add_index :agent_planning_holds, [ :issue_id, :label ], unique: true
    add_index :agent_planning_holds, [ :project_id, :status ]
  end
end
