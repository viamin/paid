# frozen_string_literal: true

class AddEnforcementModeToCostBudgets < ActiveRecord::Migration[8.1]
  def change
    add_column :cost_budgets, :enforcement_mode, :string, limit: 20, default: "alert", null: false
    add_column :cost_budgets, :grace_buffer_percent, :integer, default: 0, null: false
  end
end
