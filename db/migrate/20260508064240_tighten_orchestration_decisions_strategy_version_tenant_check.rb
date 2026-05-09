# frozen_string_literal: true

class TightenOrchestrationDecisionsStrategyVersionTenantCheck < ActiveRecord::Migration[8.1]
  def up
    create_function :validate_orchestration_decision_strategy_version_scope, version: 1
    create_trigger :validate_strategy_version_scope, on: :orchestration_decisions
  end

  def down
    execute 'DROP TRIGGER IF EXISTS "validate_strategy_version_scope" ON "orchestration_decisions"'
    execute "DROP FUNCTION IF EXISTS validate_orchestration_decision_strategy_version_scope()"
  end
end
