# frozen_string_literal: true

# idx_github_installations_on_account_installation covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5565 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :github_installations, name: "index_github_installations_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :github_installations, [ :account_id ],
      name: "index_github_installations_on_account_id", algorithm: :concurrently
  end
end
