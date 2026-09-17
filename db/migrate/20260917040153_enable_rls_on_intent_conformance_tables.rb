# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-008
class EnableRlsOnIntentConformanceTables < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      enable_rls_on_intent_conformance_verdicts if table_exists?(:intent_conformance_verdicts)
      enable_rls_on_intent_conformance_decisions if table_exists?(:intent_conformance_decisions)
    end
  end

  def down
    safety_assured do
      disable_rls_on(:intent_conformance_decisions) if table_exists?(:intent_conformance_decisions)
      disable_rls_on(:intent_conformance_verdicts) if table_exists?(:intent_conformance_verdicts)
    end
  end

  private

  # Verdicts key tenancy through their issue (issues → projects.account_id).
  def enable_rls_on_intent_conformance_verdicts
    execute "ALTER TABLE intent_conformance_verdicts ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE intent_conformance_verdicts FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON intent_conformance_verdicts
      AS PERMISSIVE
      FOR ALL
      USING (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM issues
            INNER JOIN projects ON projects.id = issues.project_id
            WHERE issues.id = intent_conformance_verdicts.issue_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      )
      WITH CHECK (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM issues
            INNER JOIN projects ON projects.id = issues.project_id
            WHERE issues.id = intent_conformance_verdicts.issue_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      )
    SQL
  end

  # Decisions additionally carry an actor user id, so — like
  # issue_merge_subscriptions — they require the actor to belong to the
  # same account as the issue's project.
  def enable_rls_on_intent_conformance_decisions
    execute "ALTER TABLE intent_conformance_decisions ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE intent_conformance_decisions FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON intent_conformance_decisions
      AS PERMISSIVE
      FOR ALL
      USING (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM issues
            INNER JOIN projects ON projects.id = issues.project_id
            WHERE issues.id = intent_conformance_decisions.issue_id
              AND projects.account_id = paid_current_account_id()
          )
          AND EXISTS (
            SELECT 1 FROM users
            WHERE users.id = intent_conformance_decisions.actor_id
              AND users.account_id = paid_current_account_id()
          )
        )
      )
      WITH CHECK (
        paid_tenant_bypass() OR (
          EXISTS (
            SELECT 1 FROM issues
            INNER JOIN projects ON projects.id = issues.project_id
            WHERE issues.id = intent_conformance_decisions.issue_id
              AND projects.account_id = paid_current_account_id()
          )
          AND EXISTS (
            SELECT 1 FROM users
            WHERE users.id = intent_conformance_decisions.actor_id
              AND users.account_id = paid_current_account_id()
          )
        )
      )
    SQL
  end

  def disable_rls_on(table)
    execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
    execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
  end
end
