# frozen_string_literal: true

class ValidateRunnerCredentialForeignKeyOnClaudeLoginSessions < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :claude_login_sessions, :runner_credentials
  end
end
