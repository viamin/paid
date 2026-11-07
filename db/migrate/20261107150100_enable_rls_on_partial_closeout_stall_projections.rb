# frozen_string_literal: true

# Tenant row-level security for the display-only partial-closeout stall
# projection tables (RDR-081): the projection is read through the same
# tenant-scoped relations as the rest of the Inbox, so another account's
# project is never visible in the projection or the lane.
# @spec PARTIAL-CLOSEOUT-042
class EnableRlsOnPartialCloseoutStallProjections < ActiveRecord::Migration[8.1]
  TABLES = %w[partial_closeout_stall_checkpoints partial_closeout_stalls].freeze

  def up
    TABLES.each do |table|
      enable_tenant_rls(table, tenant_condition(table))
    end
  end

  def down
    TABLES.each do |table|
      disable_tenant_rls(table)
    end
  end

  private

  def enable_tenant_rls(table, condition)
    safety_assured do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON #{table}
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{condition}))
      SQL
    end
  end

  def disable_tenant_rls(table)
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end

  def tenant_condition(table)
    <<~SQL.squish
      #{table}.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = #{table}.project_id
          AND projects.account_id = paid_current_account_id()
      )
      #{issue_membership_condition(table)}
    SQL
  end

  # Only the stall table carries issue membership; the checkpoint is a pure
  # project row.
  def issue_membership_condition(table)
    return "" unless table == "partial_closeout_stalls"

    <<~SQL.squish
      AND EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
        WHERE issues.id = #{table}.issue_id
          AND issues.project_id = #{table}.project_id
          AND issue_projects.account_id = paid_current_account_id()
      )
    SQL
  end
end
