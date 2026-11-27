# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-018
class ValidateFeatureIntentDecisionsSourceAgentRunForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :feature_intent_decisions, :agent_runs, column: :source_agent_run_id
  end
end
