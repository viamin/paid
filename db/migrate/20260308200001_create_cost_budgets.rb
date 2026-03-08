# frozen_string_literal: true

class CreateCostBudgets < ActiveRecord::Migration[8.1]
  def change
    create_table :cost_budgets do |t|
      t.bigint :project_id, null: false
      t.string :budget_type, limit: 50, null: false
      t.integer :limit_cents, null: false
      t.integer :current_usage_cents, default: 0, null: false
      t.integer :alert_threshold_percent, default: 80, null: false
      t.datetime :alert_sent_at
      t.datetime :period_started_at
      t.timestamps
    end

    add_index :cost_budgets, :project_id
    add_index :cost_budgets, [ :project_id, :budget_type ], unique: true
    add_foreign_key :cost_budgets, :projects, on_delete: :cascade
  end
end
