# frozen_string_literal: true

# index_chat_session_projects_on_chat_session_id_and_project_id covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5486 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :chat_session_projects, name: "index_chat_session_projects_on_chat_session_id", algorithm: :concurrently
  end

  def down
    add_index :chat_session_projects, [ :chat_session_id ],
      name: "index_chat_session_projects_on_chat_session_id", algorithm: :concurrently
  end
end
