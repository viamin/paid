# frozen_string_literal: true

class CreateQualityRecoveryActions < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_recovery_actions do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.references :prompt_version, foreign_key: { on_delete: :nullify }
      t.string :action_type, limit: 50, null: false
      t.string :status, limit: 50, default: "pending", null: false
      t.jsonb :diagnosis, default: {}, null: false
      t.jsonb :parameters, default: {}, null: false
      t.jsonb :result, default: {}, null: false
      t.decimal :quality_before, precision: 5, scale: 4
      t.decimal :quality_after, precision: 5, scale: 4
      t.datetime :executed_at
      t.datetime :evaluated_at

      t.timestamps
    end

    add_index :quality_recovery_actions, :action_type
    add_index :quality_recovery_actions, :status
    add_index :quality_recovery_actions, [ :project_id, :created_at ]
  end
end
