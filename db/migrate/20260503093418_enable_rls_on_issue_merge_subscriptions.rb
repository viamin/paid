# frozen_string_literal: true

class EnableRlsOnIssueMergeSubscriptions < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE issue_merge_subscriptions ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE issue_merge_subscriptions FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON issue_merge_subscriptions
      AS PERMISSIVE
      FOR ALL
      USING (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM issues
            INNER JOIN projects ON projects.id = issues.project_id
            WHERE issues.id = issue_merge_subscriptions.issue_id
              AND projects.account_id = paid_current_account_id()
          )
          AND EXISTS (
            SELECT 1 FROM users
            WHERE users.id = issue_merge_subscriptions.user_id
              AND users.account_id = paid_current_account_id()
          )
        )
      )
      WITH CHECK (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM issues
            INNER JOIN projects ON projects.id = issues.project_id
            WHERE issues.id = issue_merge_subscriptions.issue_id
              AND projects.account_id = paid_current_account_id()
          )
          AND EXISTS (
            SELECT 1 FROM users
            WHERE users.id = issue_merge_subscriptions.user_id
              AND users.account_id = paid_current_account_id()
          )
        )
      )
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS tenant_isolation ON issue_merge_subscriptions"
    execute "ALTER TABLE issue_merge_subscriptions NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE issue_merge_subscriptions DISABLE ROW LEVEL SECURITY"
  end
end
