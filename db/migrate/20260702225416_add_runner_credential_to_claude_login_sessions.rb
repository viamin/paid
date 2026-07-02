# frozen_string_literal: true

class AddRunnerCredentialToClaudeLoginSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:claude_login_sessions, :runner_credential_id)
      add_reference :claude_login_sessions,
        :runner_credential,
        null: true,
        index: { algorithm: :concurrently },
        comment: "Managed Claude runner credential captured when the browser login completes."
    end

    add_index :claude_login_sessions, :runner_credential_id, algorithm: :concurrently unless index_exists?(:claude_login_sessions, :runner_credential_id)
    change_column_comment :claude_login_sessions, :runner_credential_id, "Managed Claude runner credential captured when the browser login completes."
    remove_foreign_key :claude_login_sessions, :runner_credentials if foreign_key_exists?(:claude_login_sessions, :runner_credentials)
  end
end
