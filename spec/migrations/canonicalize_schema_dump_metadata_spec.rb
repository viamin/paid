# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260805002623_canonicalize_schema_dump_metadata")

RSpec.describe CanonicalizeSchemaDumpMetadata, :aggregate_failures do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  # @spec POSTGRESQL-PERSISTENCE-007
  it "records canonical metadata for schema dumps" do
    migration.up

    expect(clone_manifest_comment).to eq(described_class::CLONE_MANIFEST_COMMENT)
    expect(managed_function_names).to eq(%w[paid_current_account_id paid_tenant_bypass])
    expect(function_source("paid_current_account_id")).to include("POSTGRESQL-PERSISTENCE-007")
    expect(function_source("paid_tenant_bypass")).to include("POSTGRESQL-PERSISTENCE-007")
  end

  # @spec POSTGRESQL-PERSISTENCE-007
  it "restores the prior unmanaged function bodies and comment on rollback" do
    migration.up
    migration.down

    expect(clone_manifest_comment).to eq(described_class::LEGACY_CLONE_MANIFEST_COMMENT)
    expect(managed_function_names).to eq(%w[paid_current_account_id paid_tenant_bypass])
    expect(function_source("paid_current_account_id")).not_to include("POSTGRESQL-PERSISTENCE-007")
    expect(function_source("paid_tenant_bypass")).not_to include("POSTGRESQL-PERSISTENCE-007")
    expect(function_source("paid_current_account_id")).to include("current_setting('paid.current_account_id'")
    expect(function_source("paid_tenant_bypass")).to include("current_setting('paid.bypass_tenant_rls'")
  ensure
    migration.up
  end

  def clone_manifest_comment
    connection.select_value(<<~SQL.squish)
      SELECT col_description('chat_sessions'::regclass, ordinal_position)
      FROM information_schema.columns
      WHERE table_name = 'chat_sessions'
        AND column_name = 'clone_manifest'
    SQL
  end

  def managed_function_names
    connection.select_values(<<~SQL.squish)
      SELECT proname
      FROM pg_proc
      JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
      WHERE pg_namespace.nspname = 'public'
        AND proname IN ('paid_current_account_id', 'paid_tenant_bypass')
      ORDER BY proname
    SQL
  end

  def function_source(name)
    connection.select_value(<<~SQL.squish)
      SELECT prosrc
      FROM pg_proc
      JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
      WHERE pg_namespace.nspname = 'public'
        AND proname = #{connection.quote(name)}
    SQL
  end
end
