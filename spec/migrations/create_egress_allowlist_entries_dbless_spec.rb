# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260819003626_create_egress_allowlist_entries")

RSpec.describe CreateEgressAllowlistEntries, :no_db do
  let(:migration) { described_class.new }
  let(:table_definition_class) do
    stub_const("SpecTableDefinition", Class.new do
      def references(*) = nil
      def string(*) = nil
      def integer(*) = nil
      def boolean(*) = nil
      def text(*) = nil
      def timestamps(*) = nil
    end)
  end
  let(:table) { instance_double(table_definition_class) }

  before do
    allow(migration).to receive(:table_exists?).and_return(false)
    allow(migration).to receive(:create_table).and_yield(table)
    allow(migration).to receive(:add_index)
    allow(migration).to receive(:add_check_constraint)
    allow(migration).to receive(:execute)
    allow(table).to receive_messages(
      references: nil,
      string: nil,
      integer: nil,
      boolean: nil,
      text: nil,
      timestamps: nil
    )
  end

  it "creates the intended foreign key shape on the egress allowlist entries table" do
    migration.up

    expect_host_pattern_column
    expect_foreign_key_shape
    expect_scope_lookup_index
    expect_safety_constraints
  end

  it "enables forced tenant RLS for egress allowlist entries" do
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    joined = recorded_sql.join("\n")
    expect(joined).to include("ALTER TABLE egress_allowlist_entries ENABLE ROW LEVEL SECURITY;")
    expect(joined).to include("ALTER TABLE egress_allowlist_entries FORCE ROW LEVEL SECURITY;")
    expect(joined).to include("DROP POLICY IF EXISTS tenant_isolation ON egress_allowlist_entries;")
    expect(joined).to include("CREATE POLICY tenant_isolation ON egress_allowlist_entries")
    expect(joined).to include("paid_tenant_bypass() OR egress_allowlist_entries.account_id = paid_current_account_id()")
  end

  it "skips table recreation but still (re-)enables tenant RLS when rerun against a partially-created table" do
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:create_table)

    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.up

    expect(migration).not_to have_received(:create_table)
    joined = recorded_sql.join("\n")
    expect(joined).to include("ALTER TABLE egress_allowlist_entries ENABLE ROW LEVEL SECURITY;")
    expect(joined).to include("CREATE POLICY tenant_isolation ON egress_allowlist_entries")
  end

  it "drops the tenant isolation policy and table during rollback" do
    allow(migration).to receive(:table_exists?).and_return(true)
    allow(migration).to receive(:drop_table)

    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.down

    joined = recorded_sql.join("\n")
    expect(joined).to include("DROP POLICY IF EXISTS tenant_isolation ON egress_allowlist_entries")
    expect(joined).to include("ALTER TABLE egress_allowlist_entries NO FORCE ROW LEVEL SECURITY")
    expect(joined).to include("ALTER TABLE egress_allowlist_entries DISABLE ROW LEVEL SECURITY")
    expect(migration).to have_received(:drop_table).with(:egress_allowlist_entries, if_exists: true)
  end

  def expect_host_pattern_column
    expect(table).to have_received(:string).with(
      :host_pattern,
      null: false,
      limit: 255,
      comment: "Exact public hostname or leading-wildcard subdomain pattern (*.api.example.com)."
    )
  end

  def expect_foreign_key_shape
    expect(table).to have_received(:references).with(
      :account,
      null: false,
      foreign_key: { on_delete: :cascade },
      comment: "Owning account. Entries with a null project_id apply account-wide."
    )
    expect(table).to have_received(:references).with(
      :project,
      foreign_key: { on_delete: :cascade },
      comment: "Optional project scope. Project entries extend, never replace, account entries."
    )
  end

  def expect_scope_lookup_index
    expect(migration).to have_received(:add_index).with(
      :egress_allowlist_entries,
      [ :account_id, :project_id ],
      comment: "Account/project scope lookup used by per-run egress policy resolution."
    )
  end

  def expect_safety_constraints
    expect(migration).to have_received(:add_check_constraint).with(
      :egress_allowlist_entries,
      "port IS NULL OR (port > 0 AND port <= 65535)",
      name: "chk_egress_allowlist_entries_port_range"
    )
    expect(migration).to have_received(:add_check_constraint).with(
      :egress_allowlist_entries,
      "scheme IS NULL OR scheme IN ('http', 'https')",
      name: "chk_egress_allowlist_entries_scheme_valid"
    )
    expect(migration).to have_received(:add_check_constraint).with(
      :egress_allowlist_entries,
      "source_kind IN ('tenant', 'platform', 'operator_override')",
      name: "chk_egress_allowlist_entries_source_kind_valid"
    )
  end
end
