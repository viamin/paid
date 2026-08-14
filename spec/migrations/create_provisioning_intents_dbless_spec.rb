# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260814072312_create_provisioning_intents")

RSpec.describe CreateProvisioningIntents, :no_db do
  let(:migration) { described_class.new }
  let(:table_definition_class) do
    stub_const("ProvisioningIntentSpecTableDefinition", Class.new do
      def references(*) = nil
      def string(*) = nil
      def integer(*) = nil
      def jsonb(*) = nil
      def boolean(*) = nil
      def datetime(*) = nil
      def timestamps(*) = nil
    end)
  end
  let(:table) { instance_double(table_definition_class) }

  before do
    allow(table).to receive_messages(
      references: nil,
      string: nil,
      integer: nil,
      jsonb: nil,
      boolean: nil,
      datetime: nil,
      timestamps: nil
    )
  end

  it "returns early when the table already exists" do
    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(true)
    allow(migration).to receive(:create_table)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute)

    migration.up

    expect(migration).not_to have_received(:create_table)
    expect(migration).not_to have_received(:add_index)
    expect(migration).not_to have_received(:execute)
  end

  it "creates the intended indexes with rerun guards" do
    recorded_sql = []

    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(false)
    allow(migration).to receive(:create_table).and_yield(table)
    allow(migration).to receive(:index_exists?).and_return(false)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    expect(migration).to have_received(:add_index).with(
      :provisioning_intents,
      :provider_resource_id,
      where: "provider_resource_id IS NOT NULL",
      name: "index_provisioning_intents_on_provider_resource_id",
      unless: false
    )
    expect(migration).to have_received(:add_index).with(
      :provisioning_intents,
      [ :status, :created_at ],
      name: "index_provisioning_intents_on_status_and_created_at",
      unless: false
    )
  end

  it "creates the provisioning-intents tenant-isolation policy" do
    recorded_sql = []

    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(false)
    allow(migration).to receive(:create_table).and_yield(table)
    allow(migration).to receive(:index_exists?).and_return(false)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    expect(recorded_sql.join("\n")).to include("ALTER TABLE provisioning_intents ENABLE ROW LEVEL SECURITY;")
    expect(recorded_sql.join("\n")).to include("ALTER TABLE provisioning_intents FORCE ROW LEVEL SECURITY;")
    expect(recorded_sql.join("\n")).to include("CREATE POLICY tenant_isolation ON provisioning_intents")
  end

  it "drops the policy only when the table exists" do
    recorded_sql = []

    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(true)
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }
    allow(migration).to receive(:drop_table)

    migration.down

    expect(recorded_sql.join("\n")).to include("DROP POLICY IF EXISTS tenant_isolation ON provisioning_intents")
    expect(migration).to have_received(:drop_table).with(:provisioning_intents, if_exists: true)
  end
end
