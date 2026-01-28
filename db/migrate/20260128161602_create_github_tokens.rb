# frozen_string_literal: true

class CreateGithubTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :github_tokens do |t|
      ## Account association (multi-tenancy)
      t.references :account, null: false, foreign_key: true

      ## Creator association (which user added this token)
      ## Nullable: token persists even if the creating user is deleted
      t.references :created_by, null: true, foreign_key: { to_table: :users }

      ## Token identification
      t.string :name, null: false

      ## Encrypted token storage (Rails 7+ encryption)
      t.string :encrypted_token, null: false

      ## Token metadata
      t.jsonb :scopes, default: [], null: false
      t.datetime :expires_at
      t.datetime :last_used_at

      ## Soft delete / revocation
      t.datetime :revoked_at

      t.timestamps null: false
    end

    add_index :github_tokens, [ :account_id, :name ], unique: true
    add_index :github_tokens, :revoked_at
  end
end
