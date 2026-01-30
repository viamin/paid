# frozen_string_literal: true

class RestoreCompositeIndexOnIssuesPaidState < ActiveRecord::Migration[8.1]
  def change
    # Remove single-column index if it exists (may have been created by schema load)
    remove_index :issues, name: "index_issues_on_paid_state", if_exists: true

    # Add composite index if it doesn't already exist
    unless index_exists?(:issues, [ :project_id, :paid_state ])
      add_index :issues, [ :project_id, :paid_state ]
    end
  end
end
