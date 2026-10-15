# frozen_string_literal: true

class AddKnowledgeCredentialBindingsToUserSettings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :user_settings, :kb_embedding_provider_api_key,
      index: { algorithm: :concurrently }
    add_reference :user_settings, :kb_chat_provider_api_key,
      index: { algorithm: :concurrently }
  end
end
