# frozen_string_literal: true

class AddFeatureIntentForeignKeyToChatSessions < ActiveRecord::Migration[8.1]
  def change
    return if foreign_key_exists?(:chat_sessions, :feature_intents, column: :feature_intent_id)

    add_foreign_key :chat_sessions, :feature_intents, column: :feature_intent_id, validate: false
  end
end
