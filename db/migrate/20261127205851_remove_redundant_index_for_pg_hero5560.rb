# frozen_string_literal: true

# index_forward_work_on_completion_and_fingerprint covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5560 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_forward_work_items, name: "index_forward_work_on_completion", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_forward_work_items, [ :feature_intent_completion_id ],
      name: "index_forward_work_on_completion", algorithm: :concurrently
  end
end
