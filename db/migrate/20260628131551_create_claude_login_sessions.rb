# frozen_string_literal: true

class CreateClaudeLoginSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :claude_login_sessions do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account that owns this browser-completed Claude login session."
      t.references :created_by, null: false, foreign_key: { to_table: :users }, comment: "User who initiated the Claude browser login."
      t.references :integration_credential, null: true, foreign_key: true, comment: "Managed Claude credential captured when the login completes."
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
end
