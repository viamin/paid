# frozen_string_literal: true

# index_linear_tokens_on_account_id_and_name covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5600 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :linear_tokens, name: "index_linear_tokens_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :linear_tokens, [ :account_id ],
      name: "index_linear_tokens_on_account_id", algorithm: :concurrently
  end
end
