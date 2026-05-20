# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260519134704_create_account_activity_events")

RSpec.describe CreateAccountActivityEvents, :no_db do
  let(:migration) { described_class.new }
  let(:table_definition_class) do
    stub_const("SpecTableDefinition", Class.new do
      def references(*) = nil
      def bigint(*) = nil
      def string(*) = nil
      def jsonb(*) = nil
      def timestamps(*) = nil
    end)
  end
  let(:table) { instance_double(table_definition_class) }

  before do
    allow(migration).to receive(:create_table).and_yield(table)
    allow(migration).to receive(:add_foreign_key)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute)
    allow(table).to receive_messages(
      references: nil,
      bigint: nil,
      string: nil,
      jsonb: nil,
      timestamps: nil
    )
  end

  it "creates the intended index and foreign key shape" do
    migration.up

    expect(table).to have_received(:references).with(
      :account,
      null: false,
      foreign_key: true,
      index: false,
      comment: "Account whose administration history this event belongs to."
    )
    expect(migration).to have_received(:add_foreign_key)
      .with(:account_activity_events, :users, column: :actor_id, validate: false)
    expect(migration).to have_received(:add_index).with(:account_activity_events, :actor_id)
    expect(migration).to have_received(:add_index).with(:account_activity_events, [ :account_id, :created_at ])
    expect(migration).to have_received(:add_index).with(:account_activity_events, [ :subject_type, :subject_id ])
    expect(migration).not_to have_received(:add_index).with(:account_activity_events, :account_id)
  end

  it "enables forced tenant RLS for account activity events" do
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    expect(recorded_sql.join("\n")).to include("ALTER TABLE account_activity_events ENABLE ROW LEVEL SECURITY;")
    expect(recorded_sql.join("\n")).to include("ALTER TABLE account_activity_events FORCE ROW LEVEL SECURITY;")
    expect(recorded_sql.join("\n")).to include("CREATE POLICY tenant_isolation ON account_activity_events")
    expect(recorded_sql.join("\n")).to include("paid_tenant_bypass() OR account_id = paid_current_account_id()")
    expect(recorded_sql.join("\n")).to include("account_id = paid_current_account_id()")
  end
end
