# frozen_string_literal: true

class ValidateKnowledgeCredentialBindingForeignKeys < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :user_settings, :provider_api_keys,
      column: :kb_embedding_provider_api_key_id
    validate_foreign_key :user_settings, :provider_api_keys,
      column: :kb_chat_provider_api_key_id
  end
end
