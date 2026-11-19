# frozen_string_literal: true

require "rails_helper"

RSpec.describe SchemaColumnOrder do
  # @spec POSTGRESQL-PERSISTENCE-009
  it "omits the development-only query statistics extension from schema dumps" do
    connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter,
      extensions: %w[hstore pg_stat_statements pg_trgm])

    expect(described_class::Connection.new(connection).extensions).to eq(%w[hstore pg_trgm])
  end

  # @spec POSTGRESQL-PERSISTENCE-009
  it "dumps columns alphabetically with their definitions and indexes intact" do
    connection = ActiveRecord::Base.connection
    connection.create_table :schema_order_probe do |table|
      table.string :zebra, default: "striped", null: false, comment: "Last alphabetically"
      table.integer :alpha
      table.index :zebra
    end

    dump = -> do
      stream = StringIO.new
      connection.create_schema_dumper({}).send(:table, "schema_order_probe", stream)
      stream.string
    end
    schema = dump.call

    expect(schema.index('t.integer "alpha"')).to be < schema.index('t.string "zebra"')
    expect(schema).to include('default: "striped", null: false, comment: "Last alphabetically"')
    expect(schema).to include('t.index ["zebra"]')
    expect(dump.call).to eq(schema)
  ensure
    connection&.drop_table(:schema_order_probe, if_exists: true)
  end

  # @spec POSTGRESQL-PERSISTENCE-009
  it "preserves fx functions and triggers in repeatable full dumps" do
    dump = -> do
      stream = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
      stream.string
    end
    schema = dump.call

    expect(schema).to include('create_function :paid_current_account_id, sql_definition:')
    expect(schema).to include('create_trigger :logidze_on_projects, sql_definition:')
    expect(dump.call).to eq(schema)
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "preserves row-level security flags and policies in repeatable full dumps" do
    connection = ActiveRecord::Base.connection
    create_schema_rls_probe(connection)
    schema = dump_schema

    expect(schema).to include("ALTER TABLE \"public\".\"schema_rls_probe_enabled\" ENABLE ROW LEVEL SECURITY;")
    expect(schema).to include("ALTER TABLE \"public\".\"schema_rls_probe_enabled\" FORCE ROW LEVEL SECURITY;")
    expect(schema).to include("CREATE POLICY \"tenant_isolation\" ON \"public\".\"schema_rls_probe_enabled\"")
    expect(schema).to include("CREATE POLICY \"staged_policy\" ON \"public\".\"schema_rls_probe_staged\"")
    expect(schema).not_to include("schema_rls_probe_staged\" ENABLE ROW LEVEL SECURITY;")
    expect(schema).to include("ALTER TABLE \"public\".\"schema_rls_probe_default_deny\" ENABLE ROW LEVEL SECURITY;")
    expect(schema).not_to include("schema_rls_probe_default_deny\" FORCE ROW LEVEL SECURITY;")
    expect(schema).to include("USING ((account_id = paid_current_account_id()))")
    expect(schema.index("create_function :paid_current_account_id")).to be < schema.index("schema_rls_probe_enabled\" ENABLE")
    expect(dump_schema).to eq(schema)
  ensure
    %i[schema_rls_probe_enabled schema_rls_probe_staged schema_rls_probe_default_deny].each do |table|
      connection&.drop_table(table, if_exists: true)
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "includes every later tenant policy group required by a fresh schema load" do
    schema = dump_schema

    %w[
      chat_sessions
      execution_usages
      personal_access_tokens
      layered_verification_obligations
      layered_verification_review_packages
      maintenance_reports
      maintenance_findings
      maintenance_finding_occurrences
    ].each do |table|
      expect(schema).to include("ALTER TABLE \"public\".\"#{table}\" ENABLE ROW LEVEL SECURITY;")
      expect(schema).to include("CREATE POLICY \"tenant_isolation\" ON \"public\".\"#{table}\"")
    end
  end

  def create_schema_rls_probe(connection)
    create_schema_rls_probe_table(connection, :schema_rls_probe_enabled)
    connection.execute "ALTER TABLE schema_rls_probe_enabled ENABLE ROW LEVEL SECURITY"
    connection.execute "ALTER TABLE schema_rls_probe_enabled FORCE ROW LEVEL SECURITY"
    connection.execute <<~SQL
      CREATE POLICY tenant_isolation ON schema_rls_probe_enabled
        AS PERMISSIVE FOR ALL
        USING (account_id = paid_current_account_id())
        WITH CHECK (account_id = paid_current_account_id())
    SQL
    create_schema_rls_probe_table(connection, :schema_rls_probe_staged)
    connection.execute "CREATE POLICY staged_policy ON schema_rls_probe_staged USING (account_id = paid_current_account_id())"
    create_schema_rls_probe_table(connection, :schema_rls_probe_default_deny)
    connection.execute "ALTER TABLE schema_rls_probe_default_deny ENABLE ROW LEVEL SECURITY"
  end

  def create_schema_rls_probe_table(connection, table)
    connection.create_table(table) { |definition| definition.bigint :account_id, null: false }
  end

  def dump_schema
    stream = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
    stream.string
  end
end
