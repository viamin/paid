# frozen_string_literal: true

require "rails_helper"

RSpec.describe SchemaColumnOrder do
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
end
