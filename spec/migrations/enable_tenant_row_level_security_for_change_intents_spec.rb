# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260629035155_enable_tenant_row_level_security_for_change_intents")

RSpec.describe EnableTenantRowLevelSecurityForChangeIntents, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    migration.down if tenant_policy_present? || row_level_security_enabled?

    example.run
  ensure
    migration.down if tenant_policy_present? || row_level_security_enabled?
    migration.up
  end

  it "enables forced tenant RLS for change intents using project account scope" do
    migration.up

    expect(tenant_policy_present?).to be(true)
    expect(row_level_security_enabled?).to be(true)
    expect(row_level_security_forced?).to be(true)
    expect(change_intents_policy.fetch("qual")).to include("projects.account_id = paid_current_account_id()")
    expect(change_intents_policy.fetch("with_check")).to include("projects.account_id = paid_current_account_id()")
  end

  private

  def change_intents_policy
    connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'change_intents'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def tenant_policy_present?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'change_intents'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relrowsecurity
      FROM pg_class
      WHERE oid = 'public.change_intents'::regclass
    SQL
  end

  def row_level_security_forced?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.change_intents'::regclass
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
