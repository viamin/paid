# frozen_string_literal: true

class AddStrategyVersionToOrchestrationDecisions < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:orchestration_decisions, :strategy_version_id) &&
      foreign_key_exists?(:orchestration_decisions, :strategy_versions, column: :strategy_version_id)

    safety_assured do
      add_reference :orchestration_decisions, :strategy_version, null: true, index: true, if_not_exists: true
      add_foreign_key :orchestration_decisions, :strategy_versions,
        column: :strategy_version_id,
        on_delete: :nullify unless foreign_key_exists?(:orchestration_decisions, :strategy_versions, column: :strategy_version_id)
    end
  end

  def down
    safety_assured do
      remove_foreign_key :orchestration_decisions, column: :strategy_version_id if foreign_key_exists?(:orchestration_decisions, :strategy_versions, column: :strategy_version_id)
      remove_index :orchestration_decisions, :strategy_version_id if index_exists?(:orchestration_decisions, :strategy_version_id)
      remove_column :orchestration_decisions, :strategy_version_id if column_exists?(:orchestration_decisions, :strategy_version_id)
    end
  end
end
