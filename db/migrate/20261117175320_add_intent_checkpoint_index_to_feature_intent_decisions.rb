# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
class AddIntentCheckpointIndexToFeatureIntentDecisions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :feature_intent_decisions, :intent_checkpoint_id, algorithm: :concurrently
  end
end
