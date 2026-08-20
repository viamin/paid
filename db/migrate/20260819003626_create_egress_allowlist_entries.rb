# frozen_string_literal: true

# Tenant-managed egress allowlist entries (RDR-055). Account-wide entries have
# a nil project_id; project entries are scoped to a single project and extend
# the account set. Domain rules only — operator-only CIDR support is a future
# kind, never an overload of these rows.
#
# Forced tenant RLS is required: these rows directly extend what network
# destinations tenant agent containers may reach, so they must follow the same
# +tenant_isolation+ policy as every other account-scoped table rather than
# relying on the application-level `where(account:)` filter in
# AgentRuns::EgressPolicy::Resolve.
# @spec EGRESS-POLICY-001
class CreateEgressAllowlistEntries < ActiveRecord::Migration[8.1]
  def up
    if table_exists?(:egress_allowlist_entries)
      enable_egress_allowlist_entries_rls
      return
    end

    create_table :egress_allowlist_entries, comment: "Tenant-managed egress allowlist entries resolved into per-run egress policy snapshots (RDR-055)." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade },
        comment: "Owning account. Entries with a null project_id apply account-wide."
      t.references :project, foreign_key: { on_delete: :cascade },
        comment: "Optional project scope. Project entries extend, never replace, account entries."
      t.string :host_pattern, null: false, limit: 255,
        comment: "Exact public hostname or leading-wildcard subdomain pattern (*.api.example.com)."
      t.integer :port, comment: "Optional destination port (1-65535). Blank means any allowed port for the host."
      t.string :scheme, comment: "Optional scheme restriction: http or https."
      t.boolean :enabled, null: false, default: true, comment: "Disabled entries are skipped by policy resolution without deleting the rule."
      t.text :reason, comment: "Human-readable justification recorded in the run's policy snapshot provenance."
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify },
        comment: "User who created the entry, for audit."
      t.timestamps
    end

    add_index :egress_allowlist_entries, [ :account_id, :project_id ],
      comment: "Account/project scope lookup used by per-run egress policy resolution."

    add_check_constraint :egress_allowlist_entries,
      "host_pattern IS NOT NULL",
      name: "chk_egress_allowlist_entries_host_present"
    add_check_constraint :egress_allowlist_entries,
      "port IS NULL OR (port > 0 AND port <= 65535)",
      name: "chk_egress_allowlist_entries_port_range"
    add_check_constraint :egress_allowlist_entries,
      "scheme IS NULL OR scheme IN ('http', 'https')",
      name: "chk_egress_allowlist_entries_scheme_valid"
    add_check_constraint :egress_allowlist_entries,
      "source_kind IN ('tenant', 'platform', 'operator_override')",
      name: "chk_egress_allowlist_entries_source_kind_valid"

    enable_egress_allowlist_entries_rls
  end

  def down
    return unless table_exists?(:egress_allowlist_entries)

    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON egress_allowlist_entries"
      execute "ALTER TABLE egress_allowlist_entries NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE egress_allowlist_entries DISABLE ROW LEVEL SECURITY"
    end

    drop_table :egress_allowlist_entries, if_exists: true
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. The +DROP
  # POLICY IF EXISTS+ guard keeps the migration idempotent when rerun
  # against a partially-created table.
  def enable_egress_allowlist_entries_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE egress_allowlist_entries ENABLE ROW LEVEL SECURITY;
        ALTER TABLE egress_allowlist_entries FORCE ROW LEVEL SECURITY;
        DROP POLICY IF EXISTS tenant_isolation ON egress_allowlist_entries;
        CREATE POLICY tenant_isolation ON egress_allowlist_entries
          USING (
            paid_tenant_bypass() OR egress_allowlist_entries.account_id = paid_current_account_id()
          )
          WITH CHECK (
            paid_tenant_bypass() OR egress_allowlist_entries.account_id = paid_current_account_id()
          );
      SQL
    end
  end
end
