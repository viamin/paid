# frozen_string_literal: true

class RenameApiKeyCiphertextToApiKey < ActiveRecord::Migration[8.1]
  def change
    if column_exists?(:provider_api_keys, :api_key_ciphertext) &&
       !column_exists?(:provider_api_keys, :api_key)
      rename_column :provider_api_keys, :api_key_ciphertext, :api_key
    end
  end
end
