# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261024205417_create_facet_confidence_evaluations")

RSpec.describe CreateFacetConfidenceEvaluations, :aggregate_failures do
  # @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-021
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    tables_existed = facet_confidence_tables.to_h { |table| [ table, connection.table_exists?(table) ] }

    teardown_facet_confidence_tables!
    clear_schema_metadata!

    example.run
  ensure
    teardown_facet_confidence_tables!

    if tables_existed.any? { |_table, existed| existed }
      migration.up
    end
    clear_schema_metadata!
  end

  it "creates the evaluation tables with one-per-generation indexes and tenant RLS" do
    migration.up

    facet_confidence_tables.each { |table| expect(connection.data_source_exists?(table)).to be(true) }
    expect_schema
    expect_indexes
    facet_confidence_tables.each { |table| expect_rls_on(table) }
  end

  it "rolls back cleanly" do
    migration.up

    expect { migration.down }.not_to raise_error
    facet_confidence_tables.each { |table| expect(connection.data_source_exists?(table)).to be(false) }
  end

  private

  def facet_confidence_tables
    %w[
      facet_confidence_evaluations
      facet_confidence_evaluation_labels
    ]
  end

  def clear_schema_metadata!
    connection.schema_cache.clear!
    facet_confidence_tables.each { |table| connection.schema_cache.clear_data_source_cache!(table) }
    FacetConfidenceEvaluation.reset_column_information
    FacetConfidenceEvaluationLabel.reset_column_information
  end

  # The list is parent-first; children must drop before their parent.
  def teardown_facet_confidence_tables!
    facet_confidence_tables.reverse_each { |table| connection.drop_table(table, if_exists: true) }
  end

  def expect_schema
    evaluations = connection.columns(:facet_confidence_evaluations).index_by(&:name)
    labels = connection.columns(:facet_confidence_evaluation_labels).index_by(&:name)

    expect(evaluations.fetch("project_id").null).to be(false)
    expect(evaluations.fetch("issue_id").null).to be(false)
    expect(evaluations.fetch("status").default).to eq("labeling")
    expect(evaluations.fetch("corpus_path").null).to be(false)
    expect(evaluations.fetch("corpus_digest").null).to be(false)
    expect(connection.foreign_key_exists?(:facet_confidence_evaluations, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:facet_confidence_evaluations, :issues)).to be(true)
    expect(connection.foreign_key_exists?(:facet_confidence_evaluations, :users, column: "created_by_id")).to be(true)

    expect(labels.fetch("facet_confidence_evaluation_id").null).to be(false)
    expect(labels.fetch("case_id").null).to be(false)
    expect(labels.fetch("state").default).to eq("pending")
    expect(labels.fetch("recorded_at").null).to be(false)
    expect(connection.foreign_key_exists?(
      :facet_confidence_evaluation_labels,
      :facet_confidence_evaluations,
      column: "facet_confidence_evaluation_id"
    )).to be(true)
    expect(connection.foreign_key_exists?(
      :facet_confidence_evaluation_labels,
      :users,
      column: "recorded_by_id"
    )).to be(true)
  end

  def expect_indexes
    evaluation_indexes = connection.indexes(:facet_confidence_evaluations).index_by(&:name)
    label_indexes = connection.indexes(:facet_confidence_evaluation_labels).index_by(&:name)

    expect(evaluation_indexes.fetch("idx_facet_confidence_evaluations_one_per_closeout_generation").unique).to be(true)
    expect(evaluation_indexes.fetch("idx_facet_confidence_evaluations_one_per_closeout_generation").columns)
      .to eq(%w[issue_id corpus_digest])
    expect(label_indexes.fetch("idx_facet_confidence_evaluation_labels_case").unique).to be(true)
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
