# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261116190000_create_layered_verification_review_packages")

RSpec.describe CreateLayeredVerificationReviewPackages, :aggregate_failures do
  # @spec LAYERED-VERIFY-023
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    tables_existed = review_package_tables.to_h { |table| [ table, connection.table_exists?(table) ] }

    teardown_review_package_tables!
    clear_schema_metadata!

    example.run
  ensure
    teardown_review_package_tables!

    restore_current_schema! if tables_existed.any? { |_table, existed| existed }
    clear_schema_metadata!
  end

  it "creates the review package tables with unique identity indexes and tenant RLS" do
    migration.up

    review_package_tables.each { |table| expect(connection.data_source_exists?(table)).to be(true) }
    expect_schema
    expect_indexes
    review_package_tables.each { |table| expect_rls_on(table) }
  end

  it "rolls back cleanly" do
    migration.up

    expect { migration.down }.not_to raise_error
    review_package_tables.each { |table| expect(connection.data_source_exists?(table)).to be(false) }
  end

  private

  def review_package_tables
    %w[
      layered_verification_review_approvals
      layered_verification_review_packages
    ]
  end

  def clear_schema_metadata!
    connection.schema_cache.clear!
    review_package_tables.each { |table| connection.schema_cache.clear_data_source_cache!(table) }
    LayeredVerificationReviewPackage.reset_column_information
    LayeredVerificationReviewApproval.reset_column_information
  end

  # Approvals must drop before the packages they reference.
  def teardown_review_package_tables!
    connection.drop_table(:layered_verification_review_approvals, if_exists: true)
    connection.drop_table(:layered_verification_review_packages, if_exists: true)
  end

  def restore_current_schema!
    migration.up
  end

  def expect_schema
    packages = connection.columns(:layered_verification_review_packages).index_by(&:name)
    approvals = connection.columns(:layered_verification_review_approvals).index_by(&:name)

    expect(packages.fetch("project_id").null).to be(false)
    expect(packages.fetch("agent_run_id").null).to be(false)
    expect(packages.fetch("package_digest").null).to be(false)
    expect(packages.fetch("revision_number").null).to be(false)
    expect(packages.fetch("bound_inputs").null).to be(false)
    expect_foreign_key(:layered_verification_review_packages, :projects, on_delete: :cascade)
    expect_foreign_key(:layered_verification_review_packages, :agent_runs, on_delete: :cascade)

    expect(approvals.fetch("package_id").null).to be(false)
    expect(approvals.fetch("approved_by_id").null).to be(false)
    expect(approvals.fetch("approved_at").null).to be(false)
    expect_foreign_key(:layered_verification_review_approvals, :layered_verification_review_packages,
      column: "package_id", on_delete: :cascade)
    expect_foreign_key(:layered_verification_review_approvals, :users,
      column: "approved_by_id", on_delete: :restrict)
  end

  def expect_foreign_key(from_table, to_table, column: nil, on_delete: nil)
    foreign_key = connection.foreign_keys(from_table).find do |candidate|
      candidate.to_table == to_table.to_s && (column.nil? || candidate.column == column)
    end

    expect(foreign_key).to be_present
    expect(foreign_key.on_delete).to eq(on_delete)
  end

  def expect_indexes
    package_indexes = connection.indexes(:layered_verification_review_packages).index_by(&:name)

    expect(package_indexes.fetch("index_layered_verification_review_packages_identity").unique).to be(true)
    expect(package_indexes.fetch("index_layered_verification_review_packages_identity").columns)
      .to eq(%w[project_id package_digest])
    expect(package_indexes.fetch("index_layered_verification_review_packages_revision").unique).to be(true)
    expect(package_indexes.fetch("index_layered_verification_review_packages_revision").columns)
      .to eq(%w[agent_run_id revision_number])
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
