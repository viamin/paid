# frozen_string_literal: true

class AddKnowledgeCredentialBindingForeignKeys < ActiveRecord::Migration[8.1]
  def up
    add_foreign_key :user_settings, :provider_api_keys,
      column: :kb_embedding_provider_api_key_id, on_delete: :restrict, validate: false
    add_foreign_key :user_settings, :provider_api_keys,
      column: :kb_chat_provider_api_key_id, on_delete: :restrict, validate: false
  end

  def down
    remove_foreign_key :user_settings, column: :kb_embedding_provider_api_key_id
    remove_foreign_key :user_settings, column: :kb_chat_provider_api_key_id
  end
end
