# frozen_string_literal: true

class DropOldLoginSessionTables < ActiveRecord::Migration[8.1]
  def up
    drop_table :claude_login_sessions, if_exists: true
    drop_table :codex_login_sessions, if_exists: true
  end

  def down
    create_claude_login_sessions_table unless table_exists?(:claude_login_sessions)
    create_codex_login_sessions_table unless table_exists?(:codex_login_sessions)
  end

  private

  def create_claude_login_sessions_table
    create_table :claude_login_sessions do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account that owns this browser-completed Claude login session."
      t.references :created_by, null: false, foreign_key: { to_table: :users }, comment: "User who initiated the Claude browser login."
      t.references :integration_credential, null: true, foreign_key: true, comment: "Managed Claude credential captured when the login completes."
      t.references :runner_credential, null: true, foreign_key: true, comment: "Managed Claude runner credential captured when the browser login completes."
      t.uuid :external_id, null: false, comment: "Opaque public identifier used in user-facing URLs."
      t.string :session_token, null: false, comment: "Time-boxed shared secret required to submit the browser code."
      t.string :credential_name, null: false, comment: "IntegrationCredential name to create or replace on successful capture."
      t.string :status, null: false, default: "starting", comment: "Browser login lifecycle state."
      t.text :oauth_url
      t.text :error_message
      t.datetime :expires_at, comment: "Session expiry until completed; replaced with credential expiry after capture."
      t.datetime :submitted_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.string :container_id
      t.jsonb :metadata, null: false, default: {}, comment: "Structured runtime details such as return paths and parsed Claude metadata."

      t.timestamps
    end

    add_index :claude_login_sessions, :external_id, unique: true
    add_index :claude_login_sessions, :session_token, unique: true
  end

  def create_codex_login_sessions_table
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

    add_index :codex_login_sessions, :external_id, unique: true
    add_index :codex_login_sessions, :session_token, unique: true
  end
end
