# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261023000000_create_intent_conformance_shadow_evaluations")

RSpec.describe CreateIntentConformanceShadowEvaluations, :aggregate_failures do
  # @spec INTENT-CONFORMANCE-ROLLOUT-005 @spec INTENT-CONFORMANCE-ROLLOUT-007
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    tables_existed = shadow_evaluation_tables.to_h { |table| [ table, connection.table_exists?(table) ] }

    teardown_shadow_evaluation_tables!
    clear_schema_metadata!

    example.run
  ensure
    teardown_shadow_evaluation_tables!

    if tables_existed.any? { |_table, existed| existed }
      migration.up
    end
    clear_schema_metadata!
  end

  it "creates the shadow evaluation tables with one-per-generation indexes and tenant RLS" do
    migration.up

    shadow_evaluation_tables.each { |table| expect(connection.data_source_exists?(table)).to be(true) }
    expect_schema
    expect_indexes
    shadow_evaluation_tables.each { |table| expect_rls_on(table) }
  end

  it "rolls back cleanly" do
    migration.up

    expect { migration.down }.not_to raise_error
    shadow_evaluation_tables.each { |table| expect(connection.data_source_exists?(table)).to be(false) }
  end

  private

  def shadow_evaluation_tables
    %w[
      intent_conformance_shadow_evaluations
      intent_conformance_shadow_evaluation_labels
      intent_conformance_shadow_evaluation_runs
    ]
  end

  def clear_schema_metadata!
    connection.schema_cache.clear!
    shadow_evaluation_tables.each { |table| connection.schema_cache.clear_data_source_cache!(table) }
    IntentConformanceShadowEvaluation.reset_column_information
    IntentConformanceShadowEvaluationLabel.reset_column_information
    IntentConformanceShadowEvaluationRun.reset_column_information
  end

  # The list is parent-first; children must drop before their parent.
  def teardown_shadow_evaluation_tables!
    shadow_evaluation_tables.reverse_each { |table| connection.drop_table(table, if_exists: true) }
  end

  def expect_schema
    evaluations = connection.columns(:intent_conformance_shadow_evaluations).index_by(&:name)
    labels = connection.columns(:intent_conformance_shadow_evaluation_labels).index_by(&:name)
    runs = connection.columns(:intent_conformance_shadow_evaluation_runs).index_by(&:name)

    expect(evaluations.fetch("project_id").null).to be(false)
    expect(evaluations.fetch("policy").default).to eq("solo")
    expect(evaluations.fetch("status").default).to eq("labeling")
    expect(evaluations.fetch("manifest_path").null).to be(false)
    expect(connection.foreign_key_exists?(:intent_conformance_shadow_evaluations, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:intent_conformance_shadow_evaluations, :users, column: "solo_maintainer_id"))
      .to be(true)

    expect(labels.fetch("shadow_evaluation_id").null).to be(false)
    expect(labels.fetch("case_id").null).to be(false)
    expect(labels.fetch("state").default).to eq("pending")
    expect(connection.foreign_key_exists?(
      :intent_conformance_shadow_evaluation_labels,
      :intent_conformance_shadow_evaluations,
      column: "shadow_evaluation_id"
    )).to be(true)

    expect(runs.fetch("verdict").default).to eq("not_evaluated")
    expect(runs.fetch("recorded_at").null).to be(false)
    expect(connection.foreign_key_exists?(
      :intent_conformance_shadow_evaluation_runs,
      :intent_conformance_shadow_evaluations,
      column: "shadow_evaluation_id"
    )).to be(true)
  end

  def expect_indexes
    evaluation_indexes = connection.indexes(:intent_conformance_shadow_evaluations).index_by(&:name)
    label_indexes = connection.indexes(:intent_conformance_shadow_evaluation_labels).index_by(&:name)
    run_indexes = connection.indexes(:intent_conformance_shadow_evaluation_runs).index_by(&:name)

    expect(evaluation_indexes.fetch("idx_shadow_evaluations_one_per_evidence_generation").unique).to be(true)
    expect(evaluation_indexes.fetch("idx_shadow_evaluations_one_per_evidence_generation").columns)
      .to eq(%w[project_id purpose manifest_digest])
    expect(label_indexes.fetch("idx_shadow_evaluation_labels_case").unique).to be(true)
    expect(run_indexes.fetch("idx_shadow_evaluation_runs_case").unique).to be(true)
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
