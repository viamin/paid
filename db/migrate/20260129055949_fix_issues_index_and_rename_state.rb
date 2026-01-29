# frozen_string_literal: true

class FixIssuesIndexAndRenameState < ActiveRecord::Migration[8.1]
  def change
    # Rename github_state to state per documentation (docs/DATA_MODEL.md)
    rename_column :issues, :github_state, :state

    # Replace standalone paid_state index with composite (project_id, paid_state)
    # for efficient per-project state queries
    remove_index :issues, :paid_state
    add_index :issues, [ :project_id, :paid_state ], name: "index_issues_on_project_id_and_paid_state"
  end
end
