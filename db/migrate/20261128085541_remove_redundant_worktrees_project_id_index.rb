# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-014
class RemoveRedundantWorktreesProjectIdIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_worktrees_on_project_id"

  def up
    remove_index :worktrees, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :worktrees, :project_id, name: INDEX_NAME, algorithm: :concurrently, if_not_exists: true
  end
end
