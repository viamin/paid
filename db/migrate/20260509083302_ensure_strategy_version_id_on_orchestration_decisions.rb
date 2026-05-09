# frozen_string_literal: true

class EnsureStrategyVersionIdOnOrchestrationDecisions < ActiveRecord::Migration[8.1]
  def up
    return if ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)

    add_reference :orchestration_decisions, :strategy_version,
      null: true,
      foreign_key: { on_delete: :nullify },
      index: true
  end

  def down
    remove_reference :orchestration_decisions, :strategy_version,
      foreign_key: { on_delete: :nullify },
      index: true,
      if_exists: true
  end
end
