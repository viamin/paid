# frozen_string_literal: true

class CreateCodexLoginSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :codex_login_sessions, comment: "Device-code Connect Codex login sessions (RDR-041 / #2962)." do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account that owns this Connect Codex login session."
      t.references :created_by, null: false, foreign_key: { to_table: :users }, comment: "User who initiated the Connect Codex login."
      t.references :runner_credential, null: true, foreign_key: true, comment: "Managed Codex credential captured when the login completes."
      t.uuid :external_id, null: false, comment: "Opaque public identifier used in user-facing URLs."
      t.string :session_token, null: false, comment: "Time-boxed shared secret required to advance the device-code poll."
      t.string :credential_name, null: false, comment: "RunnerCredential name to create or replace on successful capture."
      t.string :status, null: false, default: "starting", comment: "Device-code login lifecycle state."
      t.text :device_code, comment: "Encrypted device_code used to poll the OAuth token endpoint."
      t.string :user_code, comment: "Short code the user enters at the verification URI."
      t.text :verification_uri, comment: "URI the user visits to authorize the device."
      t.integer :poll_interval, comment: "Seconds between token-endpoint polls."
      t.text :error_message
      t.datetime :expires_at, comment: "Device-code expiry; replaced with credential expiry after capture."
      t.datetime :completed_at
      t.datetime :failed_at
      t.jsonb :metadata, null: false, default: {}, comment: "Structured runtime details such as return paths and parsed Codex metadata."

      t.timestamps
    end

    # `t.references :account` already creates index_codex_login_sessions_on_account_id;
    # only the public-identifier lookups need their own unique indexes.
    add_index :codex_login_sessions, :external_id, unique: true
    add_index :codex_login_sessions, :session_token, unique: true
  end
end
