# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-006 PARTIAL-CLOSEOUT-042
class EnforcePartialCloseoutProjectionTenancy < ActiveRecord::Migration[8.1]
  TABLES = %i[partial_closeout_projections partial_closeout_projection_entries].freeze

  def up
    create_function :enforce_partial_closeout_projection_issue_project, version: 1
    create_trigger :enforce_partial_closeout_projection_issue_project, version: 1, on: :partial_closeout_projection_entries
    TABLES.each { |table| enable_policy(table) }
  end

  def down
    TABLES.reverse_each do |table|
      safety_assured do
        execute "DROP POLICY tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end
    drop_trigger :enforce_partial_closeout_projection_issue_project, on: :partial_closeout_projection_entries
    drop_function :enforce_partial_closeout_projection_issue_project
  end
  private

  def enable_policy(table)
    safety_assured do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON #{table}
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = #{table}.project_id
            AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = #{table}.project_id
            AND projects.account_id = paid_current_account_id()
        ))
      SQL
    end
  end

end
