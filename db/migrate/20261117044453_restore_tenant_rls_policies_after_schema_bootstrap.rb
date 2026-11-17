# frozen_string_literal: true

require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260426231639_enable_rls_on_chat_tables")
require Rails.root.join("db/migrate/20260826184107_enable_rls_on_execution_usages")
require Rails.root.join("db/migrate/20261010133105_enable_rls_on_personal_access_tokens")
require Rails.root.join("db/migrate/20261024055249_create_layered_verification_contracts")
require Rails.root.join("db/migrate/20261116190000_create_layered_verification_review_packages")
require Rails.root.join("db/migrate/20261116223347_create_maintenance_reports_and_findings")

# @spec POSTGRESQL-PERSISTENCE-012
class RestoreTenantRlsPoliciesAfterSchemaBootstrap < ActiveRecord::Migration[8.1]
  MAINTENANCE_TABLES = %i[
    maintenance_reports
    maintenance_findings
    maintenance_finding_occurrences
  ].freeze
  CHAT_TABLES = %i[chat_sessions chat_messages chat_session_projects].freeze
  LAYERED_VERIFICATION_TABLES = %i[
    layered_verification_obligations
    layered_verification_correspondence_claims
    layered_verification_check_results
    layered_verification_review_packages
    layered_verification_review_approvals
  ].freeze

  def up
    safety_assured do
      restore_baseline_policies
      restore_chat_policies
      restore_execution_usage_policy
      restore_personal_access_token_policy
      restore_layered_verification_policies
      restore_maintenance_policies
    end
  end

  def down
    # Schema dumps now carry policies directly. Rolling this corrective migration
    # back must not weaken an existing database boundary.
  end

  private

  def restore_baseline_policies
    EnableTenantRowLevelSecurity.new.up unless policy_present?(:accounts)
  end

  def restore_chat_policies
    restore_group(CHAT_TABLES, EnableRlsOnChatTables.new, :up)
  end

  def restore_execution_usage_policy
    restore_group([ :execution_usages ], EnableRlsOnExecutionUsages.new, :up)
  end

  def restore_personal_access_token_policy
    restore_group([ :personal_access_tokens ], EnableRlsOnPersonalAccessTokens.new, :up)
  end

  def restore_layered_verification_policies
    restore_group(LAYERED_VERIFICATION_TABLES.first(3), CreateLayeredVerificationContracts.new, :enable_rls)
    restore_group(LAYERED_VERIFICATION_TABLES.last(2), CreateLayeredVerificationReviewPackages.new, :enable_rls)
  end

  def restore_group(tables, migration, method)
    tables = tables.select { |table| table_exists?(table) }
    return if tables.empty?
    return if tables.all? { |table| policy_present?(table) }

    tables.each { |table| drop_tenant_policy(table) }
    migration.send(method)
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

  def drop_tenant_policy(table)
    return unless table_exists?(table)

    execute "DROP POLICY IF EXISTS tenant_isolation ON #{quote_table_name(table)}"
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
