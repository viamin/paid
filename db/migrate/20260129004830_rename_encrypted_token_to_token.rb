# frozen_string_literal: true

class RenameEncryptedTokenToToken < ActiveRecord::Migration[8.1]
  def change
    # Only rename if the old column exists (handles databases created with either version)
    if column_exists?(:github_tokens, :encrypted_token)
      rename_column :github_tokens, :encrypted_token, :token
    end
  end
end
