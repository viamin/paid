# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117044453_restore_tenant_rls_policies_after_schema_bootstrap")

RSpec.describe RestoreTenantRlsPoliciesAfterSchemaBootstrap do
  self.use_transactional_tests = false

  # @spec POSTGRESQL-PERSISTENCE-012
  it "repairs a missing policy group when other tenant policies remain" do
    connection = ActiveRecord::Base.connection
    connection.execute "DROP POLICY IF EXISTS tenant_isolation ON execution_usages"
    connection.execute "ALTER TABLE execution_usages DISABLE ROW LEVEL SECURITY"

    described_class.new.up

    expect(policy_present?(connection, "execution_usages")).to be(true)
    expect(row_level_security_enabled?(connection, "execution_usages")).to be(true)
    expect(policy_present?(connection, "maintenance_reports")).to be(true)
  ensure
    described_class.new.up
  end

  def policy_present?(connection, table)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = #{connection.quote(table)}
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?(connection, table)
    relation = connection.select_value(<<~SQL.squish)
      SELECT relrowsecurity FROM pg_class WHERE oid = #{connection.quote(table)}::regclass
    SQL

    [ true, "t" ].include?(relation)
  end
end
