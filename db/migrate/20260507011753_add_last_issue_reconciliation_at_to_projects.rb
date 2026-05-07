# frozen_string_literal: true

class AddLastIssueReconciliationAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_issue_reconciliation_at, :datetime, comment: "Timestamp of the last issue state reconciliation against GitHub"
  end
end
