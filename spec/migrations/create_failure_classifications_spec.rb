# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260508120219_create_failure_classifications")

RSpec.describe CreateFailureClassifications, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    table_existed = connection.table_exists?(:failure_classifications)
    migration.down if table_existed

    example.run
  ensure
    migration.down if connection.table_exists?(:failure_classifications)
    migration.up if table_existed
  end

  it "creates the table with indexes, comments, and tenant RLS" do
    migration.up

    expect(connection.table_exists?(:failure_classifications)).to be(true)
    expect_schema
    expect_indexes
    expect_comments
    expect_rls
  end

  private

  def expect_schema
    columns = connection.columns(:failure_classifications).index_by(&:name)
    expect(columns.fetch("project_id").null).to be(false)
    expect(columns.fetch("agent_run_id").null).to be(false)
    expect(columns.fetch("failure_category").limit).to eq(50)
    expect(columns.fetch("failure_subcategory").limit).to eq(100)
    expect(columns.fetch("chosen_action").limit).to eq(50)
    expect(columns.fetch("action_status").default).to eq("pending")
    expect(default_expression_for("failure_context")).to include("'{}'::jsonb")
    expect(default_expression_for("action_params")).to include("'{}'::jsonb")
    expect(default_expression_for("action_result")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:failure_classifications, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:failure_classifications, :agent_runs)).to be(true)
  end

  def expect_indexes
    index_names = connection.indexes(:failure_classifications).map(&:name)
    expect(index_names).to include(
      "index_failure_classifications_on_failure_category",
      "index_failure_classifications_on_chosen_action",
      "index_failure_classifications_on_action_status",
      "idx_failure_classifications_project_created",
      "index_failure_classifications_on_parent_workflow_id"
    )
  end

  def expect_comments
    expect(table_comment).to eq("Persisted failure classification and chosen recovery action for coordination learning")
    expect(column_comment("action_params")).to eq("Parameters passed to the chosen recovery action")
  end

  def expect_rls
    expect(tenant_policy_present?).to be(true)
    expect(row_level_security_enabled?).to be(true)
    expect(row_level_security_forced?).to be(true)
  end

  def table_comment
    connection.select_value(<<~SQL.squish)
      SELECT obj_description('public.failure_classifications'::regclass, 'pg_class')
    SQL
  end

  def column_comment(column_name)
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT col_description('public.failure_classifications'::regclass, ordinal_position)
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = 'failure_classifications'
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
          WHERE a.attrelid = 'public.failure_classifications'::regclass
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
      WHERE oid = 'public.failure_classifications'::regclass
    SQL
  end

  def row_level_security_forced?
    truthy?(connection.select_value(<<~SQL.squish))
      SELECT relforcerowsecurity
      FROM pg_class
      WHERE oid = 'public.failure_classifications'::regclass
    SQL
  end

  def tenant_policy_present?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'failure_classifications'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
