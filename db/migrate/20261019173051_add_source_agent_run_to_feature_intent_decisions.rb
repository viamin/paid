# frozen_string_literal: true

# @spec FEATURE-APPROVAL-019
class AddSourceAgentRunToFeatureIntentDecisions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:feature_intent_decisions, :source_agent_run_id)
      add_column :feature_intent_decisions, :source_agent_run_id, :bigint,
        comment: "Agent run whose recorded output explicitly emitted this decision; grounds recording and makes re-recording on a retried run a no-op."
    end
    unless foreign_key_exists?(:feature_intent_decisions, :agent_runs, column: :source_agent_run_id)
      add_foreign_key :feature_intent_decisions, :agent_runs, column: :source_agent_run_id, validate: false
    end
    unless index_exists?(:feature_intent_decisions, :source_agent_run_id)
      add_index :feature_intent_decisions, :source_agent_run_id, algorithm: :concurrently
    end
  end
end
