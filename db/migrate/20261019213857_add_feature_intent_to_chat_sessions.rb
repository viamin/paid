# frozen_string_literal: true

class AddFeatureIntentToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:chat_sessions, :feature_intent_id)
      add_reference :chat_sessions, :feature_intent, index: false,
        comment: "Feature whose related issues share this exploration conversation."
    end
    unless index_exists?(:chat_sessions, :feature_intent_id, name: "index_chat_sessions_on_feature_intent_id")
      add_index :chat_sessions, :feature_intent_id, algorithm: :concurrently,
        name: "index_chat_sessions_on_feature_intent_id"
    end
    unless index_exists?(:chat_sessions, :feature_intent_id, name: "index_chat_sessions_one_open_feature_chat")
      add_index :chat_sessions, :feature_intent_id, algorithm: :concurrently,
        unique: true,
        where: "feature_intent_id IS NOT NULL AND status != 'archived'",
        name: "index_chat_sessions_one_open_feature_chat"
    end
  end

  def down
    if index_exists?(:chat_sessions, :feature_intent_id, name: "index_chat_sessions_one_open_feature_chat")
      remove_index :chat_sessions, :feature_intent_id,
        name: "index_chat_sessions_one_open_feature_chat", algorithm: :concurrently
    end
    if index_exists?(:chat_sessions, :feature_intent_id, name: "index_chat_sessions_on_feature_intent_id")
      remove_index :chat_sessions, :feature_intent_id,
        name: "index_chat_sessions_on_feature_intent_id", algorithm: :concurrently
    end
    remove_reference :chat_sessions, :feature_intent, index: false if column_exists?(:chat_sessions, :feature_intent_id)
  end
end
