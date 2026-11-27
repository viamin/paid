# frozen_string_literal: true

# idx_agent_images_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5444 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_images, name: "index_agent_images_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :agent_images, [ :account_id ],
      name: "index_agent_images_on_account_id", algorithm: :concurrently
  end
end
