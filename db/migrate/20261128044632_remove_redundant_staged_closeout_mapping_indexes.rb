# frozen_string_literal: true

class RemoveRedundantStagedCloseoutMappingIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-014
  def up
    remove_index :staged_closeout_mappings, name: "index_staged_closeout_mappings_on_issue_id", algorithm: :concurrently, if_exists: true
    remove_index :staged_closeout_mappings, name: "index_staged_closeout_mappings_on_project_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :staged_closeout_mappings, :issue_id, algorithm: :concurrently, if_not_exists: true
    add_index :staged_closeout_mappings, :project_id, algorithm: :concurrently, if_not_exists: true
  end
end
