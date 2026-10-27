# frozen_string_literal: true

# Kept as a no-op for databases that applied the staged creation migration
# before the account reference was folded into it.
class FinalizeChatTurnsAccount < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:chat_turns, :account_id)

    add_reference :chat_turns, :account, null: false, foreign_key: true
    add_index :chat_turns, %i[account_id status activity_at]
  end

  def down
    return unless column_exists?(:chat_turns, :account_id)

    remove_reference :chat_turns, :account, foreign_key: true
  end
end
