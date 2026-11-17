# frozen_string_literal: true

require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20261116223347_create_maintenance_reports_and_findings")

# @spec POSTGRESQL-PERSISTENCE-012
class RestoreTenantRlsPoliciesAfterSchemaBootstrap < ActiveRecord::Migration[8.1]
  MAINTENANCE_TABLES = %i[
    maintenance_reports
    maintenance_findings
    maintenance_finding_occurrences
  ].freeze

  def up
    safety_assured do
      EnableTenantRowLevelSecurity.new.up unless tenant_policies_present?
      restore_maintenance_policies
    end
  end

  def down
    # Schema dumps now carry policies directly. Rolling this corrective migration
    # back must not weaken an existing database boundary.
  end

  private

  def tenant_policies_present?
    truthy?(select_value("SELECT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public')"))
  end

  def restore_maintenance_policies
    migration = CreateMaintenanceReportsAndFindings.new
    MAINTENANCE_TABLES.each do |table|
      next if policy_present?(table)

      migration.send(:enable_tenant_rls!, table)
    end
  end

  def policy_present?(table)
    truthy?(select_value(<<~SQL.squish))
      SELECT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = #{quote(table)}
          AND policyname = 'tenant_isolation'
      )
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
