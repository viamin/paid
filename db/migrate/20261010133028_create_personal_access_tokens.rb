# frozen_string_literal: true

class CreatePersonalAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :personal_access_tokens, id: :uuid, comment: "Personal access tokens for /api/v1 mobile API bearer auth. Only the SHA-256 digest of the paid_pat_ secret is persisted." do |t|
      t.references :user, null: false, foreign_key: true, comment: "Bearer subject (the user the token authenticates)."
      t.references :account, null: false, foreign_key: true, comment: "Bearer tenant (the user's account; drives tenant context on bearer resolution)."
      t.string :name, null: false, comment: "User-assigned label for the revocation UI; unique per user."
      t.string :token_digest, null: false, comment: "SHA-256 base64digest of the full paid_pat_ secret; unique."
      t.jsonb :scopes, null: false, default: [ "inbox", "chat" ], comment: "Token scopes; v1 ships the full default set."
      t.datetime :expires_at, comment: "Optional expiry; blank means no expiry."
      t.datetime :last_used_at, comment: "Throttled usage stamp (written at most once per 5 minutes); feeds the revocation UI only."
      t.datetime :revoked_at, comment: "Soft revocation timestamp; blank means active."
      t.timestamps null: false
    end

    add_index :personal_access_tokens, :token_digest, unique: true
    add_index :personal_access_tokens, [ :user_id, :name ], unique: true
    add_index :personal_access_tokens, :revoked_at
  end
end
