# frozen_string_literal: true

class CreatePersonalAccessTokens < ActiveRecord::Migration[8.1]
  def up
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

    safety_assured do
      execute <<~SQL
        ALTER TABLE personal_access_tokens ENABLE ROW LEVEL SECURITY;
        ALTER TABLE personal_access_tokens FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON personal_access_tokens
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (personal_access_tokens.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (personal_access_tokens.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON personal_access_tokens" }
    safety_assured { execute "ALTER TABLE personal_access_tokens NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE personal_access_tokens DISABLE ROW LEVEL SECURITY" }

    drop_table :personal_access_tokens
  end
end
