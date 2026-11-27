# frozen_string_literal: true

# index_explicit_preferences_on_account_id_and_user_id_and_scope covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5537 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :explicit_preferences, name: "index_explicit_preferences_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :explicit_preferences, [ :account_id ],
      name: "index_explicit_preferences_on_account_id", algorithm: :concurrently
  end
end
