# frozen_string_literal: true

class RemoveRedundantStrategyIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-021
  def up
    remove_index :strategies, name: "index_strategies_on_decision_type", algorithm: :concurrently, if_exists: true
    remove_index :strategy_versions, name: "index_strategy_versions_on_strategy_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :strategies, :decision_type, algorithm: :concurrently, if_not_exists: true
    add_index :strategy_versions, :strategy_id, algorithm: :concurrently, if_not_exists: true
  end
end
