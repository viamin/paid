# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117075035_restore_complete_tenant_policy_catalog")

# DDL remains inside each example's transaction, in the isolated test database.
# @spec POSTGRESQL-PERSISTENCE-012
RSpec.describe RestoreCompleteTenantPolicyCatalog do
  let(:connection) { ActiveRecord::Base.connection }

  def policy(table)
    connection.select_one("SELECT qual, with_check FROM pg_policies WHERE schemaname = 'public' AND tablename = '#{table}' AND policyname = 'tenant_isolation'")
  end

  def repair
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "repairs missing policies with the accounts baseline present and restores tightened write predicates" do
    original = policy("maintenance_reports")
    expect(policy("accounts")).to be_present
    connection.execute("DROP POLICY tenant_isolation ON users")
    connection.execute("DROP POLICY tenant_isolation ON layered_verification_findings")
    connection.execute("ALTER POLICY tenant_isolation ON maintenance_reports WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())")
    connection.execute("CREATE POLICY tenant_isolation_select ON configuration_bundles FOR SELECT USING (true)")

    repair

    expect(policy("users")).to be_present
    expect(policy("layered_verification_findings")).to be_present
    expect(policy("maintenance_reports")).to eq(original)
    expect(connection.select_value("SELECT 1 FROM pg_policies WHERE tablename = 'configuration_bundles' AND policyname = 'tenant_isolation_select'")).to be_nil
  end

  [ false, true ].each do |enabled|
    it "preserves an unrelated table's RLS flags when enabled is #{enabled}" do
      connection.create_table(:bootstrap_policy_probe) { |table| table.bigint :account_id }
      if enabled
        connection.execute("ALTER TABLE bootstrap_policy_probe ENABLE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE bootstrap_policy_probe FORCE ROW LEVEL SECURITY")
      else
        connection.execute("CREATE POLICY probe ON bootstrap_policy_probe USING (false)")
      end

      repair

      flags = connection.select_one("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'bootstrap_policy_probe'::regclass")
      expect(flags).to eq("relrowsecurity" => enabled, "relforcerowsecurity" => enabled)
    end
  end
end
