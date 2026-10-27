class CreateChatTurnsAndEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_turns, comment: "Durable lifecycle record for one interactive chat turn (#4680)" do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user_message, null: false, foreign_key: { to_table: :chat_messages }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :stream_message_id, comment: "Client stream id that started the turn; the key that lets a replay reuse the original user message row"
      t.string :status, null: false, default: "pending", comment: "Turn lifecycle: pending, streaming, completed, failed, stalled, or abandoned"
      t.string :classification, comment: "Why a non-terminal turn was classified stalled: never_started, ambiguous_mid_turn"
      t.datetime :last_activity_at, null: false, comment: "Last durable checkpoint (persisted message) within this turn; drives stall detection"
      t.datetime :stalled_detected_at, comment: "When the turn was last classified as stalled"
      t.boolean :side_effecting_tool_persisted, null: false, default: false, comment: "Whether a write tool call/result was persisted during this turn, for recovery-safety checks"
      t.integer :recovery_attempts_count, null: false, default: 0
      t.datetime :last_recovery_attempted_at
      t.datetime :recovering_at
      t.string :recovery_outcome, comment: "auto_recovery_attempted, user_resumed, or exhausted"
      t.jsonb :metadata, null: false, default: {}, comment: "Audit extras: stall event history, recovery source, recovery result, user action"
      t.timestamps
    end

    add_index :chat_turns, [ :chat_session_id, :stream_message_id ], unique: true
    add_index :chat_turns, [ :status, :last_activity_at ], where: "status IN ('pending', 'streaming')", name: "index_chat_turns_on_unfinished_last_activity"

    create_table :chat_turn_events do |t|
      t.references :chat_turn, null: false, foreign_key: true
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :chat_turn_events, [ :event_type, :created_at ]
  end
end
