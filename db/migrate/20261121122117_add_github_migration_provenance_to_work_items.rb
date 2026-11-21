# @spec UNIFIED-WORK-ITEMS-007
class AddGithubMigrationProvenanceToWorkItems < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :work_items, :legacy_issue, index: false,
      comment: "Legacy Paid issue aggregate retained as immutable migration provenance."
    add_index :work_items, :legacy_issue_id, unique: true, where: "legacy_issue_id IS NOT NULL", algorithm: :concurrently
  end

  def down
    remove_index :work_items, :legacy_issue_id, algorithm: :concurrently
    remove_reference :work_items, :legacy_issue
  end
end
