# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260927061548_create_intent_conformance_review_schedules")

# @spec INTENT-CONFORMANCE-010
RSpec.describe CreateIntentConformanceReviewSchedules, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    table_existed = connection.table_exists?(:intent_conformance_review_schedules)

    drop_schedules_table
    clear_schema_metadata

    example.run
  ensure
    drop_schedules_table
    migration.migrate(:up) if table_existed
    clear_schema_metadata
  end

  it "creates the schedules table with a unique identity index and tenant RLS" do
    migration.migrate(:up)

    expect(connection.data_source_exists?("intent_conformance_review_schedules")).to be(true)
    expect_columns
    expect(connection.indexes(:intent_conformance_review_schedules).map(&:name))
      .to include("idx_intent_review_schedules_unique_identity")
    expect_rls_enabled
  end

  it "rolls back cleanly" do
    migration.migrate(:up)

    expect { migration.migrate(:down) }.not_to raise_error
    expect(connection.data_source_exists?("intent_conformance_review_schedules")).to be(false)
  end

  private

  def expect_columns
    columns = connection.columns(:intent_conformance_review_schedules).index_by(&:name)

    expect(columns.fetch("issue_id").null).to be(false)
    expect(columns.fetch("pr_head_sha").null).to be(false)
    expect(columns.fetch("approved_design_revision").null).to be(false)
    expect(columns.fetch("status").null).to be(false)
    expect(columns.fetch("attempts_count").default).to eq("0")
    expect(connection.foreign_key_exists?(:intent_conformance_review_schedules, :issues)).to be(true)
    expect(connection.foreign_key_exists?(:intent_conformance_review_schedules, :projects)).to be(true)
  end

  def expect_rls_enabled
    expect(truthy?(connection.select_value(
      "SELECT relrowsecurity FROM pg_class WHERE oid = 'public.intent_conformance_review_schedules'::regclass"
    ))).to be(true)
    expect(truthy?(connection.select_value(
      "SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.intent_conformance_review_schedules'::regclass"
    ))).to be(true)

    policy = connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'intent_conformance_review_schedules'
        AND policyname = 'tenant_isolation'
    SQL
    expect(policy.fetch("qual")).to include("projects.account_id = paid_current_account_id()")
    expect(policy.fetch("with_check")).to include("projects.account_id = paid_current_account_id()")
  end

  def drop_schedules_table
    connection.drop_table(:intent_conformance_review_schedules, if_exists: true)
  end

  def clear_schema_metadata
    connection.schema_cache.clear!
    connection.schema_cache.clear_data_source_cache!("intent_conformance_review_schedules")
    IntentConformanceReviewSchedule.reset_column_information
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
