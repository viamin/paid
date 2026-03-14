# frozen_string_literal: true

class CreateCostBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :cost_budgets do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :budget_type, limit: 50, null: false
      t.integer :limit_cents, null: false
      t.integer :current_usage_cents, default: 0, null: false
      t.integer :alert_threshold_percent, default: 80, null: false
      t.datetime :alert_sent_at
      t.datetime :period_started_at
      t.timestamps
    end

    add_index :cost_budgets, [ :project_id, :budget_type ], unique: true
  end
end
