# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260917030434_create_intent_conformance_verdicts")
require Rails.root.join("db/migrate/20260917030435_create_intent_conformance_decisions")
require Rails.root.join("db/migrate/20260917040153_enable_rls_on_intent_conformance_tables")

RSpec.describe CreateIntentConformanceVerdicts, :aggregate_failures do
  # @spec INTENT-CONFORMANCE-001 @spec INTENT-CONFORMANCE-008
  self.use_transactional_tests = false

  let(:verdicts_migration) { described_class.new }
  let(:decisions_migration) { CreateIntentConformanceDecisions.new }
  let(:rls_migration) { EnableRlsOnIntentConformanceTables.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    tables_existed = connection.table_exists?(:intent_conformance_verdicts)
    rls_existed = {
      verdicts: tenant_policy_present?("intent_conformance_verdicts"),
      decisions: tenant_policy_present?("intent_conformance_decisions")
    }

    teardown_intent_conformance_tables!
    clear_schema_metadata!

    example.run
  ensure
    teardown_intent_conformance_tables!

    if tables_existed
      verdicts_migration.migrate(:up)
      decisions_migration.migrate(:up)
      rls_migration.up if rls_existed.values.any?
    end
    clear_schema_metadata!
  end

  it "creates the verdict and decision tables with indexes and tenant RLS" do
    verdicts_migration.migrate(:up)
    decisions_migration.migrate(:up)
    rls_migration.up

    expect(connection.data_source_exists?("intent_conformance_verdicts")).to be(true)
    expect(connection.data_source_exists?("intent_conformance_decisions")).to be(true)
    expect_verdict_schema
    expect_decision_schema
    expect_indexes
    expect_rls_on("intent_conformance_verdicts", actor_constrained: false)
    expect_rls_on("intent_conformance_decisions", actor_constrained: true)
  end

  it "rolls back cleanly" do
    verdicts_migration.migrate(:up)
    decisions_migration.migrate(:up)
    rls_migration.up

    expect { rls_migration.down }.not_to raise_error
    expect { decisions_migration.migrate(:down) }.not_to raise_error
    expect { verdicts_migration.migrate(:down) }.not_to raise_error
    expect(connection.data_source_exists?("intent_conformance_verdicts")).to be(false)
    expect(connection.data_source_exists?("intent_conformance_decisions")).to be(false)
  end

  private

  def clear_schema_metadata!
    connection.schema_cache.clear!
    connection.schema_cache.clear_data_source_cache!("intent_conformance_verdicts")
    connection.schema_cache.clear_data_source_cache!("intent_conformance_decisions")
    IntentConformanceVerdict.reset_column_information
    IntentConformanceDecision.reset_column_information
  end

  def teardown_intent_conformance_tables!
    rls_migration.down
    connection.drop_table(:intent_conformance_decisions, if_exists: true)
    connection.drop_table(:intent_conformance_verdicts, if_exists: true)
  end

  def expect_verdict_schema
    columns = connection.columns(:intent_conformance_verdicts).index_by(&:name)

    expect(columns.fetch("issue_id").null).to be(false)
    expect(columns.fetch("pr_head_sha").null).to be(false)
    expect(columns.fetch("outcome").null).to be(false)
    expect(columns.fetch("evaluated_at").null).to be(false)
    expect(connection.foreign_key_exists?(:intent_conformance_verdicts, :issues)).to be(true)
    expect(connection.foreign_key_exists?(:intent_conformance_verdicts, :agent_runs, column: "reviewer_run_id")).to be(true)
  end

  def expect_decision_schema
    columns = connection.columns(:intent_conformance_decisions).index_by(&:name)

    expect(columns.fetch("issue_id").null).to be(false)
    expect(columns.fetch("actor_id").null).to be(false)
    expect(columns.fetch("action").null).to be(false)
    expect(columns.fetch("head_sha").null).to be(false)
    expect(columns.fetch("reason").null).to be(false)
    expect(connection.foreign_key_exists?(:intent_conformance_decisions, :issues)).to be(true)
    expect(connection.foreign_key_exists?(:intent_conformance_decisions, :intent_conformance_verdicts, column: "verdict_id")).to be(true)
    expect(connection.foreign_key_exists?(:intent_conformance_decisions, :users, column: "actor_id")).to be(true)
  end

  def expect_indexes
    verdict_index_names = connection.indexes(:intent_conformance_verdicts).map(&:name)
    decision_index_names = connection.indexes(:intent_conformance_decisions).map(&:name)

    expect(verdict_index_names).to include("index_intent_conformance_verdicts_on_issue_head_evaluated_at")
    expect(decision_index_names).to include("index_intent_conformance_decisions_on_issue_action_head")
  end

  def expect_rls_on(table, actor_constrained:)
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
    expect(policy.fetch("qual")).to include("projects.account_id = paid_current_account_id()")
    expect(policy.fetch("with_check")).to include("projects.account_id = paid_current_account_id()")

    if actor_constrained
      expect(policy.fetch("qual")).to include("users.account_id = paid_current_account_id()")
      expect(policy.fetch("with_check")).to include("users.account_id = paid_current_account_id()")
    else
      expect(policy.fetch("qual")).not_to include("users.account_id")
    end
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
