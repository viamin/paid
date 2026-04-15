# frozen_string_literal: true

class AddKnowledgeProviderSettingsToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :kb_embedding_provider, :string, default: "openai", null: false
    add_column :user_settings, :kb_embedding_fallback_providers, :jsonb, default: [], null: false
    add_column :user_settings, :kb_chat_provider, :string, default: "claude", null: false
    add_column :user_settings, :kb_chat_fallback_providers, :jsonb, default: [], null: false
  end
end
