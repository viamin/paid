# frozen_string_literal: true

class AddParentIssueLinkedAtToIssues < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:issues, :parent_issue_linked_at)

    add_column :issues,
      :parent_issue_linked_at,
      :datetime,
      comment: "When this issue was most recently linked to its current parent issue. Distinct from updated_at so unrelated sync metadata cannot re-arm an epic acceptance audit."
  end

  def down
    remove_column :issues, :parent_issue_linked_at if column_exists?(:issues, :parent_issue_linked_at)
  end
end
