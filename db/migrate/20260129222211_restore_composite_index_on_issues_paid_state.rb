# frozen_string_literal: true

class RestoreCompositeIndexOnIssuesPaidState < ActiveRecord::Migration[8.1]
  def change
    remove_index :issues, name: "index_issues_on_paid_state"
    add_index :issues, [ :project_id, :paid_state ]
  end
end
