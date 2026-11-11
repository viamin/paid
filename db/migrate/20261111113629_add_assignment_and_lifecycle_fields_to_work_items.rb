# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-006
class AddAssignmentAndLifecycleFieldsToWorkItems < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :work_items, :native_project_id, :string,
      comment: "Provider-native project identifier (e.g. a Linear project) used to resolve mapping-driven assignment."
    add_column :work_items, :native_project_name, :string
    add_column :work_items, :assignment_review_flagged_at, :datetime,
      comment: "Set when a mapping or native project change affects this item's existing override and needs human review."
    add_column :work_items, :paid_lifecycle_state, :string,
      comment: "Normalized Paid lifecycle state, kept separately from native_state to detect simultaneous conflicting changes."
    add_column :work_items, :lifecycle_sync_source, :string,
      comment: "Which side last wrote the lifecycle state (provider or paid), used to prevent synchronization loops."
    add_column :work_items, :lifecycle_synced_at, :datetime

    add_index :work_items, :native_project_id, algorithm: :concurrently
  end
end
