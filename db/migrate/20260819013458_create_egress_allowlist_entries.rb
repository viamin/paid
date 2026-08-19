# frozen_string_literal: true

class CreateEgressAllowlistEntries < ActiveRecord::Migration[8.1]
  def up
    create_table :egress_allowlist_entries, comment: "Tenant-managed host allowlist entries that resolve into an agent run's egress policy snapshot." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: true, foreign_key: { on_delete: :cascade }
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :host_pattern, limit: 255, null: false, comment: "Hostname pattern. Supports exact hosts and leading-wildcard subdomains (e.g. *.packages.example.com)."
      t.string :scheme, limit: 10, comment: "Optional scheme filter. Allowed values: http, https. When null, applies to both."
      t.integer :port, comment: "Optional destination port. When null, applies to standard ports for the scheme."
      t.boolean :enabled, null: false, default: true
      t.text :reason, comment: "Operator-provided justification shown in audit and UI."
      t.text :rejection_reason, comment: "Server-side validation message captured when the entry was rejected (e.g. unsafe rule)."
      t.string :source_kind, limit: 20, null: false, default: "tenant", comment: "Origin of the entry (tenant, platform, operator_override) for provenance rendering on agent runs."
      t.datetime :disabled_at

      t.timestamps null: false
    end

    # Unique on (host_pattern, scheme, port) rather than host_pattern alone,
    # matching EgressAllowlistEntry#host_pattern_uniqueness_within_scope: two
    # entries for the same host are allowed as long as they differ by scheme
    # or port (e.g. api.example.com on :443 and api.example.com on :8443).
    add_index :egress_allowlist_entries, [ :account_id, :host_pattern, :scheme, :port ],
      unique: true,
      where: "project_id IS NULL",
      name: "idx_egress_allowlist_entries_account_host_unique"
    add_index :egress_allowlist_entries, [ :project_id, :host_pattern, :scheme, :port ],
      unique: true,
      where: "project_id IS NOT NULL",
      name: "idx_egress_allowlist_entries_project_host_unique"
    add_index :egress_allowlist_entries, [ :account_id, :enabled ], name: "idx_egress_allowlist_entries_account_enabled"
    add_index :egress_allowlist_entries, [ :project_id, :enabled ], name: "idx_egress_allowlist_entries_project_enabled"

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

    safety_assured do
      execute <<~SQL
        ALTER TABLE egress_allowlist_entries ENABLE ROW LEVEL SECURITY;
        ALTER TABLE egress_allowlist_entries FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON egress_allowlist_entries
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (egress_allowlist_entries.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (egress_allowlist_entries.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON egress_allowlist_entries" }
    safety_assured { execute "ALTER TABLE egress_allowlist_entries NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE egress_allowlist_entries DISABLE ROW LEVEL SECURITY" }

    drop_table :egress_allowlist_entries
  end
end
