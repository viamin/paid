# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260507164917_create_orchestration_decisions")

RSpec.describe CreateOrchestrationDecisions, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    table_existed = connection.table_exists?(:orchestration_decisions)
    migration.down if table_existed

    example.run
  ensure
    migration.down if connection.table_exists?(:orchestration_decisions)
    migration.up if table_existed
  end

  it "creates the table with indexes, foreign keys, comments, and tenant RLS" do
    migration.up

    expect(connection.table_exists?(:orchestration_decisions)).to be(true)
    expect_schema
    expect_indexes
    expect_comments
    expect_rls
  end

  private

  def expect_schema
    columns = connection.columns(:orchestration_decisions).index_by(&:name)
    expect(columns.fetch("project_id").null).to be(false)
    expect(columns.fetch("agent_run_id").null).to be(true)
    expect(columns.fetch("decision_type").limit).to eq(100)
    expect(columns.fetch("actor").limit).to eq(100)
    expect(default_expression_for("context")).to include("'{}'::jsonb")
    expect(default_expression_for("inputs")).to include("'{}'::jsonb")
    expect(default_expression_for("outputs")).to include("'{}'::jsonb")
    expect(default_expression_for("outcome_references")).to include("'[]'::jsonb")
    expect(connection.foreign_key_exists?(:orchestration_decisions, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:orchestration_decisions, :agent_runs)).to be(true)
  end

  def expect_indexes
    index_names = connection.indexes(:orchestration_decisions).map(&:name)
    expect(index_names).to include(
      "index_orchestration_decisions_on_project_id",
      "index_orchestration_decisions_on_agent_run_id",
      "idx_orchestration_decisions_project_recent",
      "idx_orchestration_decisions_project_type_created",
      "idx_orchestration_decisions_run_recent",
      "idx_orchestration_decisions_run_type_created",
      "idx_orchestration_decisions_project_actor_created"
    )
  end

  def expect_comments
    expect(table_comment).to eq("Structured log of orchestration decisions for later workflow analysis and learning.")
    expect(column_comment("outcome_references")).to eq(
      "References to later runs, metrics, or artifacts used to attribute outcomes back to this decision."
    )
  end

  def expect_rls
    expect(tenant_policy_present?).to be(true)
    expect(row_level_security_enabled?).to be(true)
    expect(row_level_security_forced?).to be(true)
  end

  def table_comment
    connection.select_value(<<~SQL.squish)
      SELECT obj_description('public.orchestration_decisions'::regclass, 'pg_class')
    SQL
  end

  def column_comment(column_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT col_description('public.orchestration_decisions'::regclass, ordinal_position)
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = 'orchestration_decisions'
            AND column_name = ?
        SQL
        column_name
      ])
    )
  end

  def default_expression_for(column_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT pg_get_expr(d.adbin, d.adrelid)
          FROM pg_attribute a
          INNER JOIN pg_attrdef d
            ON d.adrelid = a.attrelid
           AND d.adnum = a.attnum
          WHERE a.attrelid = 'public.orchestration_decisions'::regclass
            AND a.attname = ?
        SQL
        column_name
      ])
    )
  end

  def row_level_security_enabled?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relrowsecurity
      FROM pg_class
      WHERE oid = 'public.orchestration_decisions'::regclass
    SQL
  end

  def row_level_security_forced?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.orchestration_decisions'::regclass
    SQL
  end

  def tenant_policy_present?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'orchestration_decisions'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
