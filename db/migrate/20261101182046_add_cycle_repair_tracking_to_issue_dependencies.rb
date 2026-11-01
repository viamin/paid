# frozen_string_literal: true

class AddCycleRepairTrackingToIssueDependencies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :issue_dependencies, :repair_status, :string, comment: "Repair outcome state: nil/pending_sync/confirmed/failed."
    add_column :issue_dependencies, :repair_outcome, :jsonb, default: {}, null: false, comment: "Details of repair application/confirmation."
    add_column :issue_dependencies, :repair_attempts, :integer, default: 0, null: false, comment: "Number of repair application attempts."
    add_column :issue_dependencies, :repair_initiated_at, :datetime, comment: "Timestamp when repair was first initiated."

    add_index :issue_dependencies, [:issue_id, :repair_status], name: "idx_issue_dependencies_repair_status", algorithm: :concurrently
  end
end
