# frozen_string_literal: true

class AddLogidzeToCostBudgets < ActiveRecord::Migration[8.1]
  def change
    add_column :cost_budgets, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_cost_budgets, on: :cost_budgets
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_cost_budgets" on "cost_budgets";
        SQL
      end
    end
  end
end
