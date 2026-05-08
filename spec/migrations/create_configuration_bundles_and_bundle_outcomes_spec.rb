# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260508021919_create_configuration_bundles_and_bundle_outcomes")

RSpec.describe CreateConfigurationBundlesAndBundleOutcomes, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    configuration_bundles_existed = connection.table_exists?(:configuration_bundles)
    bundle_outcomes_existed = connection.table_exists?(:bundle_outcomes)

    migration.down if configuration_bundles_existed || bundle_outcomes_existed

    example.run
  ensure
    migration.down if connection.table_exists?(:bundle_outcomes) || connection.table_exists?(:configuration_bundles)
    migration.up if configuration_bundles_existed || bundle_outcomes_existed
  end

  it "creates optimizer tables with indexes, comments, and tenant RLS" do
    migration.up

    expect(connection.table_exists?(:configuration_bundles)).to be(true)
    expect(connection.table_exists?(:bundle_outcomes)).to be(true)

    expect_configuration_bundles_schema
    expect_bundle_outcomes_schema
    expect_rls("configuration_bundles")
    expect_rls("bundle_outcomes")
  end

  private

  def expect_configuration_bundles_schema
    columns = connection.columns(:configuration_bundles).index_by(&:name)
    expect(columns.fetch("account_id").null).to be(true)
    expect(columns.fetch("name").limit).to eq(255)
    expect(default_expression_for("configuration_bundles", "prompt_versions")).to include("'{}'::jsonb")
    expect(default_expression_for("configuration_bundles", "context_selector")).to include("'{}'::jsonb")

    index_names = connection.indexes(:configuration_bundles).map(&:name)
    expect(index_names).to include(
      "idx_configuration_bundles_account_active",
      "idx_configuration_bundles_one_baseline_per_account",
      "idx_configuration_bundles_one_global_baseline"
    )
    expect(table_comment("configuration_bundles")).to eq(
      "Versioned configuration bundles used by the outcome optimizer to select prompts, models, and orchestration settings."
    )
  end

  def expect_bundle_outcomes_schema
    columns = connection.columns(:bundle_outcomes).index_by(&:name)
    expect(columns.fetch("configuration_bundle_id").null).to be(false)
    expect(columns.fetch("agent_run_id").null).to be(false)
    expect(columns.fetch("project_id").null).to be(false)
    expect(default_expression_for("bundle_outcomes", "context_features")).to include("'{}'::jsonb")
    expect(default_expression_for("bundle_outcomes", "component_scores")).to include("'{}'::jsonb")

    index_names = connection.indexes(:bundle_outcomes).map(&:name)
    expect(index_names).to include(
      "idx_bundle_outcomes_bundle_recent",
      "idx_bundle_outcomes_project_recent",
      "idx_bundle_outcomes_agent_run_unique"
    )
    expect(column_comment("bundle_outcomes", "component_scores")).to eq(
      "Supporting metrics that explain how the final outcome score was composed."
    )
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
        table_name,
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

  def expect_rls(table_name)
    expect(row_level_security_enabled?(table_name)).to be(true)
    expect(row_level_security_forced?(table_name)).to be(true)
    expect(tenant_policy_present?(table_name)).to be(true)
  end

  def row_level_security_enabled?(table_name)
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relrowsecurity
      FROM pg_class
      WHERE oid = 'public.#{table_name}'::regclass
    SQL
  end

  def row_level_security_forced?(table_name)
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.#{table_name}'::regclass
    SQL
  end

  def tenant_policy_present?(table_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COUNT(*)
          FROM pg_policies
          WHERE schemaname = 'public'
            AND tablename = ?
            AND policyname = 'tenant_isolation'
        SQL
        table_name
      ])
    ).to_i.positive?
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
