# frozen_string_literal: true

class CreateRunnerCredentials < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:runner_credentials)

    create_table :runner_credentials, comment: "Account-scoped encrypted credentials for subscription runners (Claude Code, Codex, Gemini, Copilot)" do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account that owns this credential"
      t.references :created_by, foreign_key: { to_table: :users }, comment: "User who created the credential"
      t.string :runner_key, null: false, comment: "Runner provider key (e.g. claude, codex, gemini, copilot)"
      t.string :name, null: false, comment: "Human-readable label for this credential"
      t.string :auth_kind, null: false, default: "oauth_token", comment: "Authentication mechanism (oauth_token, api_key, signing_token)"
      t.boolean :long_lived, null: false, default: false, comment: "When true, skips expiry tracking and refresh (e.g. claude setup-token)"
      t.text :token, null: false, comment: "Encrypted credential token"
      t.datetime :expires_at, comment: "Token expiry time; nil means no expiry"
      t.datetime :last_used_at, comment: "Last time this credential was injected into a container"
      t.datetime :revoked_at, comment: "Set when credential is revoked; nil means active"
      t.jsonb :metadata, null: false, default: {}, comment: "Arbitrary provider-specific metadata"
      t.jsonb :log_data, comment: "Logidze change tracking"

      t.timestamps
    end

    add_index :runner_credentials, [ :account_id, :runner_key, :name ], unique: true,
      name: "idx_runner_credentials_on_account_runner_key_name"
    add_index :runner_credentials, [ :account_id, :runner_key ]
    add_index :runner_credentials, [ :account_id, :revoked_at ]

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_runner_credentials, on: :runner_credentials
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_runner_credentials" on "runner_credentials";
        SQL
      end
    end
  end
end
