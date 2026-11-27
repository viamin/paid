# frozen_string_literal: true

# index_inbox_removals_user_request_occurrence covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5569 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :inbox_removals, name: "index_inbox_removals_on_user_id", algorithm: :concurrently
  end

  def down
    add_index :inbox_removals, [ :user_id ],
      name: "index_inbox_removals_on_user_id", algorithm: :concurrently
  end
end
