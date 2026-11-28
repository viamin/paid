# frozen_string_literal: true

class RemoveRedundantWorkItemExecutionIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-024
  def up
    remove_index :work_item_assignments, name: "index_work_item_assignments_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :work_item_assignments, name: "index_work_item_assignments_on_work_item_id", algorithm: :concurrently, if_exists: true
    remove_index :work_item_continuation_grants, name: "index_work_item_continuation_grants_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :work_item_continuation_grants, name: "index_work_item_continuation_grants_on_issue_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :work_item_assignments, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :work_item_assignments, :work_item_id, algorithm: :concurrently, if_not_exists: true
    add_index :work_item_continuation_grants, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :work_item_continuation_grants, :issue_id, algorithm: :concurrently, if_not_exists: true
  end
end
