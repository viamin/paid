# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260508020046_extract_exception_incidents_policy_restore_from_strategy_rls")

RSpec.describe ExtractExceptionIncidentsPolicyRestoreFromStrategyRls, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    migration.down
    example.run
  ensure
    migration.down
  end

  it "restores the expanded exception incident policy and rolls back to the original definition" do
    expect_rls_policy

    migration.up

    expect_rls_policy

    migration.down

    expect_rls_policy
  end

  private

  def expect_rls_policy
    expect(policy.fetch("permissive")).to eq("PERMISSIVE")
    expect(policy.fetch("cmd")).to eq("ALL")
    expect(policy.fetch("qual")).to eq("(paid_tenant_bypass() OR (account_id = paid_current_account_id()))")
    expect(policy.fetch("with_check")).to eq("(paid_tenant_bypass() OR (account_id = paid_current_account_id()))")
    expect(row_level_security_enabled?).to be(true)
    expect(row_level_security_forced?).to be(true)
  end

  def policy
    connection.select_one(<<~SQL.squish)
      SELECT permissive, cmd, qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'exception_incidents'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relrowsecurity
      FROM pg_class
      WHERE oid = 'public.exception_incidents'::regclass
    SQL
  end

  def row_level_security_forced?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.exception_incidents'::regclass
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
