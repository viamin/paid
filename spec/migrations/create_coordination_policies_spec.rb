# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260509101016_create_coordination_policies")

RSpec.describe CreateCoordinationPolicies, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    versions_existed = connection.table_exists?(:coordination_policy_versions)
    policies_existed = connection.table_exists?(:coordination_policies)
    migration.down if versions_existed || policies_existed

    example.run
  ensure
    migration.down if connection.table_exists?(:coordination_policy_versions) || connection.table_exists?(:coordination_policies)
    migration.up if policies_existed || versions_existed
  end

  it "creates the policy catalog and version tables with indexes, comments, and tenant RLS" do
    migration.up

    expect(connection.table_exists?(:coordination_policies)).to be(true)
    expect(connection.table_exists?(:coordination_policy_versions)).to be(true)
    expect_policy_schema
    expect_version_schema
    expect_indexes
    expect_comments
    expect_rls("coordination_policies")
    expect_rls("coordination_policy_versions")
  end

  private

  def expect_policy_schema
    columns = connection.columns(:coordination_policies).index_by(&:name)
    expect(columns.fetch("account_id").null).to be(false)
    expect(columns.fetch("project_id").null).to be(true)
    expect(columns.fetch("policy_type").limit).to eq(50)
    expect(columns.fetch("policy_key").limit).to eq(100)
    expect(columns.fetch("status").default).to eq("draft")
    expect(default_expression_for("coordination_policies", "context_selector")).to include("'{}'::jsonb")
    expect(default_expression_for("coordination_policies", "metadata")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:coordination_policies, :accounts)).to be(true)
    expect(connection.foreign_key_exists?(:coordination_policies, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:coordination_policies, :coordination_policy_versions, column: :current_version_id)).to be(true)
  end

  def expect_version_schema
    columns = connection.columns(:coordination_policy_versions).index_by(&:name)
    expect(columns.fetch("coordination_policy_id").null).to be(false)
    expect(columns.fetch("version").null).to be(false)
    expect(columns.fetch("status").default).to eq("draft")
    expect(default_expression_for("coordination_policy_versions", "rules")).to include("'{}'::jsonb")
    expect(default_expression_for("coordination_policy_versions", "parameters")).to include("'{}'::jsonb")
    expect(default_expression_for("coordination_policy_versions", "metadata")).to include("'{}'::jsonb")
    expect(connection.foreign_key_exists?(:coordination_policy_versions, :coordination_policies)).to be(true)
  end

  def expect_indexes
    policy_indexes = connection.indexes(:coordination_policies).index_by(&:name)
    version_indexes = connection.indexes(:coordination_policy_versions).map(&:name)

    expect(policy_indexes.keys).to include(
      "idx_coordination_policies_account_type_status",
      "idx_coordination_policies_project_type_status",
      "idx_coordination_policies_account_scope_key",
      "idx_coordination_policies_project_scope_key",
      "index_coordination_policies_on_current_version_id"
    )
    expect(policy_indexes.fetch("idx_coordination_policies_account_scope_key").unique).to be(true)
    expect(policy_indexes.fetch("idx_coordination_policies_account_scope_key").where).to include("project_id IS NULL")
    expect(policy_indexes.fetch("idx_coordination_policies_project_scope_key").unique).to be(true)
    expect(policy_indexes.fetch("idx_coordination_policies_project_scope_key").where).to include("project_id IS NOT NULL")
    expect(version_indexes).to include(
      "idx_coordination_policy_versions_unique_version",
      "idx_coordination_policy_versions_one_active",
      "idx_coordination_policy_versions_policy_status_created"
    )
  end

  def expect_comments
    expect(table_comment("coordination_policies")).to eq(
      "Versioned coordination policy catalogs that drive decomposition, recovery, escalation, and lifecycle decisions."
    )
    expect(column_comment("coordination_policy_versions", "llm_prompt")).to eq(
      "Optional prompt template used when the policy delegates part of the decision to an LLM."
    )
  end

  def expect_rls(table_name)
    expect(tenant_policy_present?(table_name)).to be(true)
    expect(row_level_security_enabled?(table_name)).to be(true)
    expect(row_level_security_forced?(table_name)).to be(true)
    return unless table_name == "coordination_policies"

    expect(coordination_policy_policy.fetch("qual")).to include("projects.account_id = paid_current_account_id()")
    expect(coordination_policy_policy.fetch("with_check")).to include("projects.account_id = paid_current_account_id()")
  end

  def coordination_policy_policy
    connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'coordination_policies'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def table_comment(table_name)
    connection.select_value("SELECT obj_description('public.#{table_name}'::regclass, 'pg_class')")
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
        table_name, column_name
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
          WHERE a.attrelid = 'public.#{table_name}'::regclass
            AND a.attname = ?
        SQL
        column_name
      ])
    )
  end

  def row_level_security_enabled?(table_name)
    truthy?(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.#{table_name}'::regclass"))
  end

  def row_level_security_forced?(table_name)
    truthy?(connection.select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.#{table_name}'::regclass"))
  end

  def tenant_policy_present?(table_name)
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = '#{table_name}'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
