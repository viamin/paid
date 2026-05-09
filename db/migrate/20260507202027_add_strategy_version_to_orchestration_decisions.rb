# frozen_string_literal: true

class AddStrategyVersionToOrchestrationDecisions < ActiveRecord::Migration[8.1]
  def change
    add_reference :orchestration_decisions,
      :strategy_version,
      null: true,
      foreign_key: { on_delete: :nullify },
      index: true,
      if_not_exists: true
  end
end
