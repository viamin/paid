# frozen_string_literal: true

class AddUniqueApprovedAppleWorkflowRevisionIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_apple_workflow_revisions_one_approved_per_project"

  def up
    add_index :apple_verification_workflow_revisions, :project_id,
      unique: true,
      where: "status = 'approved'",
      name: INDEX_NAME,
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :apple_verification_workflow_revisions,
      name: INDEX_NAME,
      algorithm: :concurrently,
      if_exists: true
  end
end
