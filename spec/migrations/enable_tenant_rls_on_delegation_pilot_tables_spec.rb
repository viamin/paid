# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261107154500_enable_tenant_rls_on_delegation_pilot_tables")

RSpec.describe EnableTenantRlsOnDelegationPilotTables do
  let(:migration) { described_class.new }

  def policy_count(table)
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = '#{table}' AND policyname = 'tenant_isolation'"
    ).to_i
  end

  def rls_enabled?(table)
    ActiveRecord::Type::Boolean.new.cast(
      ActiveRecord::Base.connection.select_value(
        "SELECT relrowsecurity FROM pg_class WHERE relname = '#{table}'"
      )
    )
  end

  after do
    migration.up
  end

  it "enables forced tenant RLS with a tenant-scoped policy on both pilot tables" do
    migration.down
    expect(policy_count(:delegation_pilot_enrollments)).to eq(0)
    expect(policy_count(:delegation_pilot_metric_snapshots)).to eq(0)

    migration.up

    [ :delegation_pilot_enrollments, :delegation_pilot_metric_snapshots ].each do |table|
      expect(rls_enabled?(table)).to be(true)
      expect(policy_count(table)).to eq(1)
    end

    policy = ActiveRecord::Base.connection.select_one(
      "SELECT qual, with_check FROM pg_policies WHERE tablename = 'delegation_pilot_metric_snapshots' AND policyname = 'tenant_isolation'"
    )
    expect(policy["qual"]).to include("paid_tenant_bypass()", "paid_current_account_id()", "delegation_pilot_enrollments")
    expect(policy["with_check"]).to include("paid_tenant_bypass()", "paid_current_account_id()")
  end

  it "removes the policies on rollback" do
    migration.down

    expect(policy_count(:delegation_pilot_enrollments)).to eq(0)
    expect(policy_count(:delegation_pilot_metric_snapshots)).to eq(0)
  end
end
