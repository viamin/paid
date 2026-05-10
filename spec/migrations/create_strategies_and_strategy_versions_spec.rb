# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260507195716_create_strategies_and_strategy_versions")

RSpec.describe CreateStrategiesAndStrategyVersions, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    strategies_table_existed = connection.table_exists?(:strategies)
    strategy_versions_table_existed = connection.table_exists?(:strategy_versions)

    migration.down if strategy_versions_table_existed || strategies_table_existed
    Strategy.reset_column_information
    StrategyVersion.reset_column_information

    example.run
  ensure
    migration.down if connection.table_exists?(:strategy_versions) || connection.table_exists?(:strategies)

    if strategies_table_existed || strategy_versions_table_existed
      migration.up
    end

    Strategy.reset_column_information
    StrategyVersion.reset_column_information
  end

  it "creates strategy tables with scoped uniqueness, promotion safety, and foreign keys" do
    migration.up

    expect(connection.table_exists?(:strategies)).to be(true)
    expect(connection.table_exists?(:strategy_versions)).to be(true)

    expect_strategy_schema
    expect_strategy_indexes
    expect_strategy_comments
    expect_strategy_version_schema
    expect_strategy_version_indexes
    expect_strategy_version_comments
  end

  private

  def expect_strategy_schema
    columns = connection.columns(:strategies).index_by(&:name)

    expect(columns.fetch("slug").null).to be(false)
    expect(columns.fetch("slug").limit).to eq(100)
    expect(columns.fetch("decision_type").null).to be(false)
    expect(columns.fetch("decision_type").limit).to eq(100)
    expect(columns.fetch("status").null).to be(false)
    expect(columns.fetch("status").default).to eq("active")
    expect(default_expression_for(:strategies, "selection_rules")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:strategies, :accounts)).to be(true)
    expect(connection.foreign_key_exists?(:strategies, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:strategies, :strategy_versions, column: :current_version_id)).to be(true)
  end

  def expect_strategy_indexes
    expect(index_names(:strategies)).to include(
      "index_strategies_on_current_version_id",
      "index_strategies_on_decision_type",
      "index_strategies_on_status",
      "index_strategies_on_decision_type_and_status",
      "index_strategies_on_slug_global",
      "index_strategies_on_slug_account",
      "index_strategies_on_slug_project"
    )

    expect(check_constraint_exists?(:strategies, "chk_strategies_scope_consistency")).to be(true)
  end

  def expect_strategy_comments
    expect(table_comment(:strategies)).to eq("Scoped orchestration strategies selected for workflow decisions.")
    expect(column_comment(:strategies, "selection_rules")).to eq(
      "Structured scope and context rules used to select the strategy."
    )
  end

  def expect_strategy_version_schema
    columns = connection.columns(:strategy_versions).index_by(&:name)

    expect(columns.fetch("strategy_id").null).to be(false)
    expect(columns.fetch("version").null).to be(false)
    expect(columns.fetch("promotion_state").null).to be(false)
    expect(columns.fetch("promotion_state").default).to eq("draft")
    expect(default_expression_for(:strategy_versions, "content")).to include("'{}'::jsonb")
    expect(default_expression_for(:strategy_versions, "provenance")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:strategy_versions, :strategies)).to be(true)
    expect(connection.foreign_key_exists?(:strategy_versions, :users, column: :created_by_user_id)).to be(true)
    expect(connection.foreign_key_exists?(:strategy_versions, :strategy_versions, column: :parent_version_id)).to be(true)
    expect(connection.foreign_key_exists?(:strategy_versions, :users, column: :promoted_by_user_id)).to be(true)
  end

  def expect_strategy_version_indexes
    expect(index_names(:strategy_versions)).to include(
      "index_strategy_versions_on_strategy_id_and_version",
      "index_strategy_versions_on_strategy_and_promotion_state",
      "index_strategy_versions_on_retired_at",
      "index_strategy_versions_one_active_per_strategy"
    )
  end

  def expect_strategy_version_comments
    expect(table_comment(:strategy_versions)).to eq("Versioned orchestration strategy payloads and promotion history.")
    expect(column_comment(:strategy_versions, "content")).to eq(
      "Structured orchestration behavior moved out of hardcoded workflow logic."
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

  def check_constraint_exists?(table_name, constraint_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COUNT(*)
          FROM pg_constraint
          WHERE conrelid = ?::regclass
            AND conname = ?
        SQL
        "public.#{table_name}",
        constraint_name
      ])
    ).to_i.positive?
  end
end
