# frozen_string_literal: true

class CreateLoginSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :login_sessions do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account that owns this login session."
      t.references :created_by, null: false, foreign_key: { to_table: :users }, comment: "User who initiated the login."
      t.references :integration_credential, null: true, foreign_key: true, comment: "Managed credential (Claude only)."
      t.references :runner_credential, null: true, foreign_key: true, comment: "Managed credential (Codex only)."
      t.string :provider, null: false, comment: "Provider: claude or codex."
      t.uuid :external_id, null: false, comment: "Opaque public identifier used in user-facing URLs."
      t.string :session_token, null: false, comment: "Time-boxed shared secret."
      t.string :credential_name, null: false, comment: "Credential name to create or replace on successful capture."
      t.string :status, null: false, default: "starting", comment: "Login lifecycle state."
      t.text :oauth_url, comment: "OAuth URL (Claude only)."
      t.text :device_code, comment: "Encrypted device_code (Codex only)."
      t.string :user_code, comment: "Short code the user enters (Codex only)."
      t.text :verification_uri, comment: "URI the user visits to authorize (Codex only)."
      t.integer :poll_interval, comment: "Seconds between token-endpoint polls (Codex only)."
      t.text :error_message
      t.datetime :expires_at, comment: "Session/device-code expiry."
      t.datetime :submitted_at, comment: "When code was submitted (Claude only)."
      t.datetime :completed_at
      t.datetime :failed_at
      t.string :container_id, comment: "Container ID (Claude only)."
      t.jsonb :metadata, null: false, default: {}, comment: "Structured runtime details."

      t.timestamps
    end

    add_index :login_sessions, :external_id, unique: true
    add_index :login_sessions, :session_token, unique: true
  end
end
