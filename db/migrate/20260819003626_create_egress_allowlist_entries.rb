# frozen_string_literal: true

# Tenant-managed egress allowlist entries (RDR-055). Account-wide entries have
# a nil project_id; project entries are scoped to a single project and extend
# the account set. Domain rules only — operator-only CIDR support is a future
# kind, never an overload of these rows.
# @spec EGRESS-POLICY-001
class CreateEgressAllowlistEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :egress_allowlist_entries, comment: "Tenant-managed egress allowlist entries resolved into per-run egress policy snapshots (RDR-055)." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade },
        comment: "Owning account. Entries with a null project_id apply account-wide."
      t.references :project, foreign_key: { on_delete: :cascade },
        comment: "Optional project scope. Project entries extend, never replace, account entries."
      t.string :host_pattern, null: false, limit: 253,
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
  end
end
