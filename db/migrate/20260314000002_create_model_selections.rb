# frozen_string_literal: true

class CreateModelSelections < ActiveRecord::Migration[8.1]
  def change
    create_table :model_selections do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :llm_model, null: false, foreign_key: true
      t.string :selector_type, limit: 50, null: false
      t.text :reasoning
      t.jsonb :candidates, default: [], null: false
      t.integer :budget_limit_cents
      t.decimal :complexity_score, precision: 4, scale: 2
      t.integer :selection_duration_ms

      t.timestamps null: false
    end

    add_index :model_selections, :agent_run_id, unique: true
    add_index :model_selections, :selector_type

    add_column :projects, :model_preferences, :jsonb, default: {}, null: false
  end
end
