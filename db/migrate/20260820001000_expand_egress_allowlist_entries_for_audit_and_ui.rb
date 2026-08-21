# frozen_string_literal: true

# Additive ALTER companion to the merged 20260819013458 create migration:
# merged migrations are never rewritten, so the per-run resolution lookup
# index (the query path AgentRuns::EgressPolicy::Resolve#load_entries targets)
# is added here. Every statement is guarded so the migration is a safe no-op
# wherever the columns/indexes already exist. Indexes build concurrently
# (strong_migrations) so existing databases take no write lock.
class ExpandEgressAllowlistEntriesForAuditAndUi < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  SCOPE_LOOKUP_INDEX = "idx_egress_allowlist_entries_account_project_scope"

  def up
    add_column :egress_allowlist_entries, :source_kind, :string,
      limit: 20,
      default: "tenant",
      null: false,
      comment: "Origin of the entry (tenant, platform, operator_override) for provenance rendering on agent runs." unless column_exists?(:egress_allowlist_entries, :source_kind)
    add_column :egress_allowlist_entries, :disabled_at, :datetime unless column_exists?(:egress_allowlist_entries, :disabled_at)

    add_index :egress_allowlist_entries,
      "account_id, host_pattern, COALESCE(scheme, ''), COALESCE(port, -1)",
      unique: true,
      where: "project_id IS NULL",
      name: "idx_egress_allowlist_entries_account_host_unique",
      algorithm: :concurrently unless index_exists?(:egress_allowlist_entries, name: "idx_egress_allowlist_entries_account_host_unique")
    add_index :egress_allowlist_entries,
      "project_id, host_pattern, COALESCE(scheme, ''), COALESCE(port, -1)",
      unique: true,
      where: "project_id IS NOT NULL",
      name: "idx_egress_allowlist_entries_project_host_unique",
      algorithm: :concurrently unless index_exists?(:egress_allowlist_entries, name: "idx_egress_allowlist_entries_project_host_unique")
    add_index :egress_allowlist_entries, [ :account_id, :enabled ],
      name: "idx_egress_allowlist_entries_account_enabled",
      algorithm: :concurrently unless index_exists?(:egress_allowlist_entries, [ :account_id, :enabled ], name: "idx_egress_allowlist_entries_account_enabled")
    add_index :egress_allowlist_entries, [ :project_id, :enabled ],
      name: "idx_egress_allowlist_entries_project_enabled",
      algorithm: :concurrently unless index_exists?(:egress_allowlist_entries, [ :project_id, :enabled ], name: "idx_egress_allowlist_entries_project_enabled")

    add_index :egress_allowlist_entries, [ :account_id, :project_id ],
      name: SCOPE_LOOKUP_INDEX,
      comment: "Account/project scope lookup used by per-run egress policy resolution.",
      algorithm: :concurrently unless index_exists?(:egress_allowlist_entries, [ :account_id, :project_id ], name: SCOPE_LOOKUP_INDEX)
  end

  def down
    remove_index :egress_allowlist_entries, name: SCOPE_LOOKUP_INDEX if index_exists?(:egress_allowlist_entries, [ :account_id, :project_id ], name: SCOPE_LOOKUP_INDEX)

    remove_index :egress_allowlist_entries, name: "idx_egress_allowlist_entries_project_enabled" if index_exists?(:egress_allowlist_entries, [ :project_id, :enabled ], name: "idx_egress_allowlist_entries_project_enabled")
    remove_index :egress_allowlist_entries, name: "idx_egress_allowlist_entries_account_enabled" if index_exists?(:egress_allowlist_entries, [ :account_id, :enabled ], name: "idx_egress_allowlist_entries_account_enabled")
    remove_index :egress_allowlist_entries, name: "idx_egress_allowlist_entries_project_host_unique" if index_exists?(:egress_allowlist_entries, name: "idx_egress_allowlist_entries_project_host_unique")
    remove_index :egress_allowlist_entries, name: "idx_egress_allowlist_entries_account_host_unique" if index_exists?(:egress_allowlist_entries, name: "idx_egress_allowlist_entries_account_host_unique")

    remove_column :egress_allowlist_entries, :disabled_at if column_exists?(:egress_allowlist_entries, :disabled_at)
    remove_column :egress_allowlist_entries, :source_kind if column_exists?(:egress_allowlist_entries, :source_kind)
  end
end
