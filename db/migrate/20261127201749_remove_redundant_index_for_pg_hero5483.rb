# frozen_string_literal: true

# idx_on_clarifying_question_progress_id_created_at_25dd030c72 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5483 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :chat_investigations, name: "index_chat_investigations_on_clarifying_question_progress_id", algorithm: :concurrently
  end

  def down
    add_index :chat_investigations, [ :clarifying_question_progress_id ],
      name: "index_chat_investigations_on_clarifying_question_progress_id", algorithm: :concurrently
  end
end
