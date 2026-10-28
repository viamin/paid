# frozen_string_literal: true

class CreateChatTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :chat_turns, comment: "Durable lifecycle and recovery audit record for one chat turn." do |t|
      t.references :chat_session, null: false, foreign_key: { on_delete: :cascade }
      t.references :user_message, foreign_key: { to_table: :chat_messages, on_delete: :nullify }
      t.string :stream_message_id, null: false, comment: "Client stream identifier that deduplicates a dispatched turn."
      t.string :status, null: false, default: "pending", comment: "pending, streaming, awaiting_confirmation, completed, failed, stalled, or abandoned"
      t.string :classification, comment: "Machine-readable terminal or recovery classification."
      t.datetime :last_activity_at, null: false, comment: "Most recent durable turn activity used by stall detection."
      t.datetime :completed_at, comment: "When the turn reached a terminal completed or failed outcome."
      t.datetime :stalled_at, comment: "When server-side inactivity detection classified the turn as stalled."
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true, algorithm: :concurrently
    add_index :chat_turns, [ :status, :last_activity_at ], algorithm: :concurrently
    add_reference :chat_messages, :chat_turn, foreign_key: { on_delete: :nullify }, index: { algorithm: :concurrently }, comment: "Durable chat turn that produced this transcript row."
  end
end
