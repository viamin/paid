# frozen_string_literal: true

class MigrateLoginSessionsData < ActiveRecord::Migration[8.1]
  def up
    # Migrate Claude login sessions
    if table_exists?(:claude_login_sessions)
      execute <<-SQL
        INSERT INTO login_sessions (
          account_id, created_by_id, integration_credential_id, runner_credential_id,
          provider, external_id, session_token, credential_name, status,
          oauth_url, error_message, expires_at, submitted_at, completed_at, failed_at,
          container_id, metadata, created_at, updated_at
        )
        SELECT
          account_id, created_by_id, integration_credential_id, NULL,
          'claude', external_id, session_token, credential_name, status,
          oauth_url, error_message, expires_at, submitted_at, completed_at, failed_at,
          container_id, COALESCE(metadata, '{}'::jsonb), created_at, updated_at
        FROM claude_login_sessions
      SQL
    end

    # Migrate Codex login sessions
    if table_exists?(:codex_login_sessions)
      execute <<-SQL
        INSERT INTO login_sessions (
          account_id, created_by_id, integration_credential_id, runner_credential_id,
          provider, external_id, session_token, credential_name, status,
          device_code, user_code, verification_uri, poll_interval,
          error_message, expires_at, completed_at, failed_at,
          metadata, created_at, updated_at
        )
        SELECT
          account_id, created_by_id, NULL, runner_credential_id,
          'codex', external_id, session_token, credential_name, status,
          device_code, user_code, verification_uri, poll_interval,
          error_message, expires_at, completed_at, failed_at,
          COALESCE(metadata, '{}'::jsonb), created_at, updated_at
        FROM codex_login_sessions
      SQL
    end
  end

  def down
    # Delete migrated data
    execute "DELETE FROM login_sessions WHERE provider IN ('claude', 'codex')"
  end
end
