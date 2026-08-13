# frozen_string_literal: true

class AddCaseInsensitiveOwnerNameIndexToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Supports the LEFT JOIN in IssueDependency.external_resolved_for_account,
  # which auto-pick scans every tick to decide whether cross-repo dependencies
  # still block. Without a functional index the join falls back to a sequence
  # scan of projects per external dep row. Existing indexes on
  # (account_id, owner, name) are case-sensitive and the comparison runs
  # against LOWER(owner) / LOWER(name).
  def change
    add_index :projects,
      "account_id, LOWER(owner), LOWER(name)",
      name: "index_projects_on_account_id_and_lower_owner_name",
      algorithm: :concurrently
  end
end
