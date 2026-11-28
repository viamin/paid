# @spec POSTGRESQL-PERSISTENCE-014
class RemoveDuplicateIntentCheckpointSettlementIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  DUPLICATE_INDEX = "idx_on_intent_checkpoint_id_afe16ad6d6"
  COVERING_INDEX = "idx_pd_intent_settlements_checkpoint_created"

  def up
    remove_index :project_delegation_intent_settlements,
      name: DUPLICATE_INDEX,
      algorithm: :concurrently,
      if_exists: true
  end

  def down
    add_index :project_delegation_intent_settlements,
      :intent_checkpoint_id,
      name: DUPLICATE_INDEX,
      algorithm: :concurrently,
      if_not_exists: true
  end
end
