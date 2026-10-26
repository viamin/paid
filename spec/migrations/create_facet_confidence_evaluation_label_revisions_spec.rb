# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261026194943_create_facet_confidence_evaluation_label_revisions")

RSpec.describe CreateFacetConfidenceEvaluationLabelRevisions, :aggregate_failures do
  # @spec FACET-CONFIDENCE-021
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:table) { :facet_confidence_evaluation_label_revisions }

  around do |example|
    table_existed = connection.table_exists?(table)
    connection.drop_table(table, if_exists: true)
    clear_schema_metadata!

    example.run
  ensure
    connection.drop_table(table, if_exists: true)
    migration.up if table_existed
    clear_schema_metadata!
  end

  it "creates a tenant-isolated revision table" do
    migration.up

    expect(connection.data_source_exists?(table)).to be(true)
    expect(connection.foreign_key_exists?(table, :facet_confidence_evaluation_labels)).to be(true)
    expect(row_level_security_enabled?).to be(true)
    expect(row_level_security_forced?).to be(true)
    expect(tenant_policy.fetch("qual")).to include("facet_confidence_evaluation_labels")
    expect(tenant_policy.fetch("qual")).to include("facet_confidence_evaluations")
    expect(tenant_policy.fetch("qual")).to include("projects.account_id")
    expect(tenant_policy.fetch("with_check")).to include("paid_current_account_id()")
  end

  it "rolls back cleanly" do
    migration.up

    expect { migration.down }.not_to raise_error
    expect(connection.data_source_exists?(table)).to be(false)
  end

  private

  def clear_schema_metadata!
    connection.schema_cache.clear!
    connection.schema_cache.clear_data_source_cache!(table)
    FacetConfidenceEvaluationLabelRevision.reset_column_information
  end

  def tenant_policy
    connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '#{table}'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?
    truthy?(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.#{table}'::regclass"))
  end

  def row_level_security_forced?
    truthy?(connection.select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.#{table}'::regclass"))
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
