# frozen_string_literal: true

# index_chat_investigations_on_project_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5484 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :chat_investigations, name: "index_chat_investigations_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :chat_investigations, [ :project_id ],
      name: "index_chat_investigations_on_project_id", algorithm: :concurrently
  end
end
