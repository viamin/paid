# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117075035_restore_complete_tenant_policy_catalog")

# DDL remains inside each example's transaction, in the isolated test database.
# @spec POSTGRESQL-PERSISTENCE-012
RSpec.describe RestoreCompleteTenantPolicyCatalog do
  # This migration is also the cleanup boundary for non-transactional migration
  # examples that precede it in a randomized shard. Keep its catalog durable so
  # the following schema-bootstrap examples exercise the canonical boundary.
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  before do
    connection.drop_table(:bootstrap_policy_probe, if_exists: true)
    repair
  end

  after do
    connection.drop_table(:bootstrap_policy_probe, if_exists: true)
    repair
  end

  def policy(table)
    connection.select_one("SELECT qual, with_check FROM pg_policies WHERE schemaname = 'public' AND tablename = '#{table}' AND policyname = 'tenant_isolation'")
  end

  def repair
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it "repairs missing policies with the accounts baseline present and restores tightened write predicates" do
    original = policy("projects")
    expect(original.fetch("with_check")).to include("github_tokens")
    expect(policy("accounts")).to be_present
    connection.execute("DROP POLICY tenant_isolation ON users")
    connection.execute("DROP POLICY tenant_isolation ON layered_verification_findings")
    connection.execute("ALTER POLICY tenant_isolation ON projects WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id())")
    connection.execute("CREATE POLICY tenant_isolation_select ON configuration_bundles FOR SELECT USING (true)")

    repair

    expect(policy("users")).to be_present
    expect(policy("layered_verification_findings")).to be_present
    expect(policy("projects")).to eq(original)
    expect(connection.select_value("SELECT 1 FROM pg_policies WHERE tablename = 'configuration_bundles' AND policyname = 'tenant_isolation_select'")).to be_nil
  end

  # @spec POSTGRESQL-PERSISTENCE-013
  it "retains nonrecursive strategy policies when later reference guards are installed" do
    original = connection.select_all("SELECT tablename, policyname, qual, with_check FROM pg_policies WHERE tablename IN ('strategies', 'strategy_versions') ORDER BY tablename, policyname").to_a

    repair

    restored = connection.select_all("SELECT tablename, policyname, qual, with_check FROM pg_policies WHERE tablename IN ('strategies', 'strategy_versions') ORDER BY tablename, policyname").to_a
    expect(restored).to eq(original)
    TenantContext.with(nil) do
      expect { connection.select_all("SELECT 1 FROM strategies LIMIT 0") }.not_to raise_error
      expect { connection.select_all("SELECT 1 FROM strategy_versions LIMIT 0") }.not_to raise_error
    end
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
