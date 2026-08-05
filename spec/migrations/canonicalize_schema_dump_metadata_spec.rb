# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260805002623_canonicalize_schema_dump_metadata")

RSpec.describe CanonicalizeSchemaDumpMetadata, :aggregate_failures do
  let(:migration) { described_class.new }

  # @spec POSTGRESQL-PERSISTENCE-007
  it "records canonical metadata for schema dumps" do
    migration.up

    comment = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT col_description('chat_sessions'::regclass, ordinal_position)
      FROM information_schema.columns
      WHERE table_name = 'chat_sessions'
        AND column_name = 'clone_manifest'
    SQL
    function_names = ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT proname
      FROM pg_proc
      JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
      WHERE pg_namespace.nspname = 'public'
        AND proname IN ('paid_current_account_id', 'paid_tenant_bypass')
      ORDER BY proname
    SQL

    expect(comment).to eq(described_class::CLONE_MANIFEST_COMMENT)
    expect(function_names).to eq(%w[paid_current_account_id paid_tenant_bypass])
  end
end
