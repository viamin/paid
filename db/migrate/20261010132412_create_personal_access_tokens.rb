# frozen_string_literal: true

class CreatePersonalAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :personal_access_tokens, id: :uuid, comment: "Bearer tokens for the versioned mobile API." do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false, comment: "SHA-256 digest; plaintext is never persisted."
      t.jsonb :scopes, null: false, default: []
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :personal_access_tokens, :token_digest, unique: true
    add_index :personal_access_tokens, [ :user_id, :name ], unique: true
  end
end
