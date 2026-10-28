# frozen_string_literal: true

class ChangeChatTurnStreamIdToString < ActiveRecord::Migration[8.1]
  def up
    safety_assured { change_column :chat_turns, :stream_id, :string }
  end

  def down
    safety_assured { change_column :chat_turns, :stream_id, :uuid, using: "stream_id::uuid" }
  end
end
