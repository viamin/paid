# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261024055249_create_layered_verification_contracts")

RSpec.describe CreateLayeredVerificationContracts, :aggregate_failures do
  # @spec LAYERED-VERIFY-004 @spec LAYERED-VERIFY-006
  # @spec LAYERED-VERIFY-007 @spec LAYERED-VERIFY-008
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    tables_existed = layered_verification_tables.to_h { |table| [ table, connection.table_exists?(table) ] }

    teardown_layered_verification_tables!
    clear_schema_metadata!

    example.run
  ensure
    teardown_layered_verification_tables!

    if tables_existed.any? { |_table, existed| existed }
      migration.up
    end
    clear_schema_metadata!
  end

  it "creates the layered verification contract tables with tenant RLS" do
    migration.up

    layered_verification_tables.each { |table| expect(connection.data_source_exists?(table)).to be(true) }
    expect_schema
    expect_indexes
    layered_verification_tables.each { |table| expect_rls_on(table) }
  end

  it "rolls back cleanly" do
    migration.up

    expect { migration.down }.not_to raise_error
    layered_verification_tables.each { |table| expect(connection.data_source_exists?(table)).to be(false) }
  end

  private

  def layered_verification_tables
    %w[
      layered_verification_obligations
      layered_verification_correspondence_claims
      layered_verification_check_results
    ]
  end

  def clear_schema_metadata!
    connection.schema_cache.clear!
    layered_verification_tables.each { |table| connection.schema_cache.clear_data_source_cache!(table) }
    LayeredVerificationObligation.reset_column_information
    LayeredVerificationCorrespondenceClaim.reset_column_information
    LayeredVerificationCheckResult.reset_column_information
  end

  # The list is parent-first; children must drop before their parent.
  def teardown_layered_verification_tables!
    layered_verification_tables.reverse_each { |table| connection.drop_table(table, if_exists: true) }
  end

  def expect_schema
    obligations = connection.columns(:layered_verification_obligations).index_by(&:name)
    claims = connection.columns(:layered_verification_correspondence_claims).index_by(&:name)
    results = connection.columns(:layered_verification_check_results).index_by(&:name)

    expect(obligations.fetch("project_id").null).to be(false)
    expect(obligations.fetch("framework").null).to be(false)
    expect(obligations.fetch("external_identity").null).to be(false)
    expect(obligations.fetch("approval_state").default).to eq("unresolved")
    expect_foreign_key(:layered_verification_obligations, :projects, on_delete: :cascade)
    expect_foreign_key(:layered_verification_obligations, :layered_verification_obligations,
      column: "superseded_by_id", on_delete: :nullify)

    expect(claims.fetch("obligation_id").null).to be(false)
    expect(claims.fetch("claim_type").null).to be(false)
    expect_foreign_key(:layered_verification_correspondence_claims, :layered_verification_obligations,
      column: "obligation_id", on_delete: :cascade)

    expect(results.fetch("obligation_id").null).to be(false)
    expect(results.fetch("producer").null).to be(false)
    expect(results.fetch("execution_state").null).to be(false)
    expect(results.fetch("obligation_coverage").null).to be(false)
    expect_foreign_key(:layered_verification_check_results, :layered_verification_obligations,
      column: "obligation_id", on_delete: :cascade)
    expect_foreign_key(:layered_verification_check_results, :layered_verification_correspondence_claims,
      column: "correspondence_claim_id", on_delete: :cascade)
    expect(connection.foreign_key_exists?(:layered_verification_check_results, :agent_runs)).to be(true)
  end

  def expect_foreign_key(from_table, to_table, column: nil, on_delete: nil)
    foreign_key = connection.foreign_keys(from_table).find do |candidate|
      candidate.to_table == to_table.to_s && (column.nil? || candidate.column == column)
    end

    expect(foreign_key).to be_present
    expect(foreign_key.on_delete).to eq(on_delete)
  end

  def expect_indexes
    obligation_indexes = connection.indexes(:layered_verification_obligations).index_by(&:name)

    expect(obligation_indexes.fetch("index_layered_verification_obligations_identity").unique).to be(true)
    expect(obligation_indexes.fetch("index_layered_verification_obligations_identity").columns)
      .to eq(%w[project_id framework external_identity])
  end

  def expect_rls_on(table)
    expect(tenant_policy_present?(table)).to be(true)
    expect(row_level_security_enabled?(table)).to be(true)
    expect(row_level_security_forced?(table)).to be(true)

    policy = connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '#{table}'
        AND policyname = 'tenant_isolation'
    SQL
    expect(policy.fetch("qual")).to include("paid_tenant_bypass()")
    expect(policy.fetch("with_check")).to include("paid_tenant_bypass()")
  end

  def tenant_policy_present?(table)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '#{table}'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?(table)
    truthy?(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.#{table}'::regclass"))
  end

  def row_level_security_forced?(table)
    truthy?(connection.select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.#{table}'::regclass"))
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
