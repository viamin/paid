# frozen_string_literal: true

class EnableRlsOnChatTables < ActiveRecord::Migration[8.1]
  def up
    # Phase 2 (#2115) renamed the `providers` table to `runners`. When this
    # historical migration is replayed against a post-rename test DB, the
    # `FROM providers` subqueries below would fail with PG::UndefinedTable.
    # Resolve the correct table name at runtime so the migration is safe
    # to replay in either world. Production was unaffected at original
    # apply time (table was still `providers`); the policy expressions
    # are stored by OID and follow the renamed table automatically.
    connection = ActiveRecord::Base.connection
    runner_table = connection.table_exists?(:providers) ? "providers" : "runners"
    runner_id_column = connection.column_exists?(:chat_sessions, :provider_id) ? "provider_id" : "runner_id"

    safety_assured do
      # chat_sessions: direct account_id
      execute <<~SQL
        ALTER TABLE chat_sessions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_sessions FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_sessions
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              chat_sessions.account_id = paid_current_account_id()
              AND (
                chat_sessions.project_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM projects
                  WHERE projects.id = chat_sessions.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              AND (
                chat_sessions.#{runner_id_column} IS NULL
                OR EXISTS (
                  SELECT 1 FROM #{runner_table}
                  WHERE #{runner_table}.id = chat_sessions.#{runner_id_column}
                    AND #{runner_table}.user_id IN (
                      SELECT users.id FROM users
                      WHERE users.account_id = paid_current_account_id()
                    )
                )
              )
              AND (
                chat_sessions.created_by_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM users
                  WHERE users.id = chat_sessions.created_by_id
                    AND users.account_id = paid_current_account_id()
                )
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              chat_sessions.account_id = paid_current_account_id()
              AND (
                chat_sessions.project_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM projects
                  WHERE projects.id = chat_sessions.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              AND (
                chat_sessions.#{runner_id_column} IS NULL
                OR EXISTS (
                  SELECT 1 FROM #{runner_table}
                  WHERE #{runner_table}.id = chat_sessions.#{runner_id_column}
                    AND #{runner_table}.user_id IN (
                      SELECT users.id FROM users
                      WHERE users.account_id = paid_current_account_id()
                    )
                )
              )
              AND (
                chat_sessions.created_by_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM users
                  WHERE users.id = chat_sessions.created_by_id
                    AND users.account_id = paid_current_account_id()
                )
              )
            )
          );
      SQL

      # chat_messages: through chat_session
      execute <<~SQL
        ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_messages FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_messages
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_messages.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_messages.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          );
      SQL

      # chat_session_projects: through chat_session and project
      execute <<~SQL
        ALTER TABLE chat_session_projects ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_session_projects FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_session_projects
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM chat_sessions
                WHERE chat_sessions.id = chat_session_projects.chat_session_id
                  AND chat_sessions.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = chat_session_projects.project_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM chat_sessions
                WHERE chat_sessions.id = chat_session_projects.chat_session_id
                  AND chat_sessions.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = chat_session_projects.project_id
                  AND projects.account_id = paid_current_account_id()
              )
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      %w[chat_sessions chat_messages chat_session_projects].each do |table|
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end
  end
end
