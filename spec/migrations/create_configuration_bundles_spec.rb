# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260508014445_create_configuration_bundles")
require Rails.root.join("db/migrate/20260508020000_add_runtime_fields_to_configuration_bundles")

RSpec.describe CreateConfigurationBundles, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:runtime_fields_migration) { AddRuntimeFieldsToConfigurationBundles.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    configuration_bundles_table_existed = connection.table_exists?(:configuration_bundles)
    bundle_outcomes_table_existed = connection.table_exists?(:bundle_outcomes)
    configuration_bundle_id_existed = connection.column_exists?(:agent_runs, :configuration_bundle_id)

    teardown_optimizer_schema
    ConfigurationBundle.reset_column_information
    BundleOutcome.reset_column_information
    AgentRun.reset_column_information

    example.run
  ensure
    teardown_optimizer_schema

    migration.up if configuration_bundles_table_existed || bundle_outcomes_table_existed
    runtime_fields_migration.up if configuration_bundle_id_existed

    ConfigurationBundle.reset_column_information
    BundleOutcome.reset_column_information
    AgentRun.reset_column_information
  end

  it "creates configuration bundle and outcome tables for optimization lookups" do
    migration.up
    runtime_fields_migration.up

    expect(connection.table_exists?(:configuration_bundles)).to be(true)
    expect(connection.table_exists?(:bundle_outcomes)).to be(true)
    expect(connection.column_exists?(:agent_runs, :configuration_bundle_id)).to be(true)

    expect_configuration_bundle_schema
    expect_configuration_bundle_indexes
    expect_configuration_bundle_comments
    expect_bundle_outcome_schema
    expect_bundle_outcome_indexes
    expect_bundle_outcome_comments
    expect_agent_run_bundle_reference
  end

  private

  def teardown_optimizer_schema
    runtime_fields_migration.down if connection.column_exists?(:agent_runs, :configuration_bundle_id)
    migration.down if connection.table_exists?(:bundle_outcomes) || connection.table_exists?(:configuration_bundles)
  end

  def expect_configuration_bundle_schema
    columns = connection.columns(:configuration_bundles).index_by(&:name)

    expect(columns.fetch("account_id").null).to be(false)
    expect(columns.fetch("version").null).to be(false)
    expect(default_expression_for(:configuration_bundles, "version")).to include("1")
    expect(columns.fetch("name").null).to be(false)
    expect(columns.fetch("name").limit).to eq(255)
    expect(columns.fetch("status").null).to be(false)
    expect(columns.fetch("status").default).to eq("draft")
    expect(columns.fetch("status").limit).to eq(50)
    expect(columns.fetch("strategy").limit).to eq(100)
    expect(columns.fetch("fingerprint").limit).to eq(64)
    expect(default_expression_for(:configuration_bundles, "strategy_params")).to include("'{}'::jsonb")
    expect(default_expression_for(:configuration_bundles, "context")).to include("'{}'::jsonb")
    expect(default_expression_for(:configuration_bundles, "definition")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:configuration_bundles, :accounts)).to be(true)
    expect(connection.foreign_key_exists?(:configuration_bundles, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:configuration_bundles, :prompt_versions)).to be(true)
    expect(connection.foreign_key_exists?(:configuration_bundles, :llm_models)).to be(true)
  end

  def expect_configuration_bundle_indexes
    expect(index_names(:configuration_bundles)).to include(
      "index_config_bundles_unique_version_account",
      "index_config_bundles_unique_version_project",
      "index_config_bundles_on_account_status",
      "index_config_bundles_on_project_status",
      "index_config_bundles_unique_fingerprint",
      "index_configuration_bundles_on_account_id",
      "index_configuration_bundles_on_project_id",
      "index_configuration_bundles_on_prompt_version_id",
      "index_configuration_bundles_on_llm_model_id",
      "index_configuration_bundles_on_status"
    )
  end

  def expect_configuration_bundle_comments
    expect(table_comment(:configuration_bundles)).to eq(
      "Versioned snapshots of configuration components used for agent runs"
    )
    expect(column_comment(:configuration_bundles, "context")).to eq(
      "Additional context such as guardrails, token budgets, or feature flags"
    )
    expect(column_comment(:configuration_bundles, "definition")).to eq(
      "Canonical runtime configuration snapshot used for optimization and fingerprinting"
    )
  end

  def expect_bundle_outcome_schema
    columns = connection.columns(:bundle_outcomes).index_by(&:name)

    expect(columns.fetch("configuration_bundle_id").null).to be(false)
    expect(columns.fetch("agent_run_id").null).to be(false)
    expect(columns.fetch("success").null).to be(false)
    expect(columns.fetch("success").default).to be(false)
    expect(default_expression_for(:bundle_outcomes, "metrics")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:bundle_outcomes, :configuration_bundles)).to be(true)
    expect(connection.foreign_key_exists?(:bundle_outcomes, :agent_runs)).to be(true)
  end

  def expect_bundle_outcome_indexes
    expect(index_names(:bundle_outcomes)).to include(
      "index_bundle_outcomes_unique_run",
      "index_bundle_outcomes_on_agent_run_id",
      "index_bundle_outcomes_on_quality_score",
      "index_bundle_outcomes_on_success"
    )
  end

  def expect_bundle_outcome_comments
    expect(table_comment(:bundle_outcomes)).to eq(
      "Measured results from using a configuration bundle on an agent run"
    )
    expect(column_comment(:bundle_outcomes, "metrics")).to eq(
      "Additional outcome metrics (lines changed, test pass rate, etc.)"
    )
  end

  def expect_agent_run_bundle_reference
    expect(connection.foreign_key_exists?(:agent_runs, :configuration_bundles)).to be(true)
    expect(index_names(:agent_runs)).to include("index_agent_runs_on_configuration_bundle_id")
    expect(column_comment(:agent_runs, "configuration_bundle_id")).to eq(
      "Configuration bundle assigned to the run before execution."
    )
  end

  def index_names(table_name)
    connection.indexes(table_name).map(&:name)
  end

  def table_comment(table_name)
    connection.select_value(<<~SQL.squish)
      SELECT obj_description('public.#{table_name}'::regclass, 'pg_class')
    SQL
  end

  def column_comment(table_name, column_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT col_description('public.#{table_name}'::regclass, ordinal_position)
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = ?
            AND column_name = ?
        SQL
        table_name.to_s,
        column_name
      ])
    )
  end

  def default_expression_for(table_name, column_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT pg_get_expr(d.adbin, d.adrelid)
          FROM pg_attribute a
          INNER JOIN pg_attrdef d
            ON d.adrelid = a.attrelid
           AND d.adnum = a.attnum
          WHERE a.attrelid = ?::regclass
            AND a.attname = ?
        SQL
        "public.#{table_name}",
        column_name
      ])
    )
  end
end
