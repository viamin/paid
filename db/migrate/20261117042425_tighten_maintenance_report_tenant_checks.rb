# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-006 MAINT-025
class TightenMaintenanceReportTenantChecks < ActiveRecord::Migration[8.1]
  TABLES = %i[maintenance_reports maintenance_findings maintenance_finding_occurrences].freeze

  def up
    create_function :enforce_maintenance_report_references, version: 1
    TABLES.each do |table|
      create_trigger :"enforce_#{table}_references", version: 1, on: table
      safety_assured do
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute <<~SQL
          CREATE POLICY tenant_isolation ON #{table}
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())
        SQL
      end
    end
  end

  def down
    TABLES.reverse_each { |table| drop_trigger :"enforce_#{table}_references", on: table }
    drop_function :enforce_maintenance_report_references
  end
end
