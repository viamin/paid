# frozen_string_literal: true

class FixOrchestrationStrategiesUniqueIndex < ActiveRecord::Migration[8.1]
  def change
    remove_index :orchestration_strategies,
      name: "idx_orchestration_strategies_active_type_account"

    add_index :orchestration_strategies, [ :strategy_type, :account_id ],
      unique: true,
      nulls_not_distinct: true,
      where: "active = true",
      name: "idx_orchestration_strategies_active_type_account"
  end
end
