# frozen_string_literal: true

# index_personal_access_tokens_on_user_id_and_name covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5754 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :personal_access_tokens, name: "index_personal_access_tokens_on_user_id", algorithm: :concurrently
  end

  def down
    add_index :personal_access_tokens, [ :user_id ],
      name: "index_personal_access_tokens_on_user_id", algorithm: :concurrently
  end
end
