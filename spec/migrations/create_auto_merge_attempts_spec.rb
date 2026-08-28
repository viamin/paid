# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260826020009_create_auto_merge_attempts")
require Rails.root.join("db/migrate/20260826082056_enable_rls_on_auto_merge_attempts")

RSpec.describe CreateAutoMergeAttempts, :aggregate_failures do
  # @spec AUTO-MERGE-004
  self.use_transactional_tests = false

  let(:create_migration) { described_class.new }
  let(:rls_migration) { EnableRlsOnAutoMergeAttempts.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    table_existed = connection.table_exists?(:auto_merge_attempts)
    rls_existed = tenant_policy_present?

    teardown_auto_merge_attempts!
    clear_schema_metadata!(connection)

    example.run
  ensure
    teardown_auto_merge_attempts!

    if table_existed
      create_migration.up
      rls_migration.up if rls_existed
    end
    clear_schema_metadata!(connection)
  end

  it "creates the sanitized auto-merge attempt table with indexes and tenant RLS" do
    create_migration.up
    rls_migration.up

    expect(connection.data_source_exists?("auto_merge_attempts")).to be(true)
    expect_schema
    expect_indexes
    expect_rls
  end

  it "rolls back cleanly" do
    create_migration.up
    rls_migration.up

    expect { rls_migration.down }.not_to raise_error
    expect { create_migration.down }.not_to raise_error
    expect(connection.data_source_exists?("auto_merge_attempts")).to be(false)
  end

  private

  def clear_schema_metadata!(connection)
    connection.schema_cache.clear!
    connection.schema_cache.clear_data_source_cache!("auto_merge_attempts")
    AutoMergeAttempt.reset_column_information
  end

  def teardown_auto_merge_attempts!
    rls_migration.down if tenant_policy_present?
    connection.drop_table(:auto_merge_attempts, if_exists: true)
  end

  def expect_schema
    columns = connection.columns(:auto_merge_attempts).index_by(&:name)

    expect(columns.fetch("project_id").null).to be(false)
    expect(columns.fetch("issue_id").null).to be(false)
    expect(columns.fetch("attempted_at").null).to be(false)
    expect(columns.fetch("actor_path").null).to be(false)
    expect(columns.fetch("status").null).to be(false)
    expect(columns.fetch("reason_code").null).to be(true)
    expect(columns.fetch("sanitized_message").null).to be(true)
    expect(columns.fetch("credential_mode").null).to be(true)
    expect(connection.foreign_key_exists?(:auto_merge_attempts, :projects)).to be(true)
    expect(connection.foreign_key_exists?(:auto_merge_attempts, :issues)).to be(true)
  end

  def expect_indexes
    index_names = connection.indexes(:auto_merge_attempts).map(&:name)

    expect(index_names).to include(
      "index_auto_merge_attempts_on_issue_id_and_attempted_at",
      "index_auto_merge_attempts_on_project_id_and_attempted_at"
    )
    expect(index_names).not_to include(
      "index_auto_merge_attempts_on_issue_id",
      "index_auto_merge_attempts_on_project_id"
    )
  end

  def expect_rls
    expect(tenant_policy_present?).to be(true)
    expect(row_level_security_enabled?).to be(true)
    expect(row_level_security_forced?).to be(true)

    policy = connection.select_one(<<~SQL.squish)
      SELECT qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'auto_merge_attempts'
        AND policyname = 'tenant_isolation'
    SQL
    expect(policy.fetch("qual")).to include("projects.account_id = paid_current_account_id()")
    expect(policy.fetch("with_check")).to include("projects.account_id = paid_current_account_id()")
  end

  def tenant_policy_present?
    connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'auto_merge_attempts'
        AND policyname = 'tenant_isolation'
    SQL
  end

  def row_level_security_enabled?
    truthy?(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'public.auto_merge_attempts'::regclass"))
  end

  def row_level_security_forced?
    truthy?(connection.select_value("SELECT relforcerowsecurity FROM pg_class WHERE oid = 'public.auto_merge_attempts'::regclass"))
  end

  def truthy?(value)
    value == true || value == "t"
  end
end
