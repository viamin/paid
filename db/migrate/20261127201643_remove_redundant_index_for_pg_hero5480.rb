# frozen_string_literal: true

# index_chat_diagram_comments_on_chat_diagram_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5480 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :chat_diagram_comments, name: "index_chat_diagram_comments_on_chat_diagram_id", algorithm: :concurrently
  end

  def down
    add_index :chat_diagram_comments, [ :chat_diagram_id ],
      name: "index_chat_diagram_comments_on_chat_diagram_id", algorithm: :concurrently
  end
end
