# frozen_string_literal: true

class RemoveRedundantProjectDelegationIntentCheckpointIndex < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  def up
    remove_index :project_delegation_intent_checkpoints,
      name: "idx_on_feature_intent_id_529a7745bc",
      algorithm: :concurrently
  end

  def down
    add_index :project_delegation_intent_checkpoints,
      :feature_intent_id,
      name: "idx_on_feature_intent_id_529a7745bc",
      algorithm: :concurrently
  end
end
