# frozen_string_literal: true

class AddPartialCompletionToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :issues, :partial_completion_at, :datetime,
      comment: "When an evidence-backed assessment recorded that a merged implementation PR left this source issue incomplete." unless column_exists?(:issues, :partial_completion_at)
    add_column :issues, :partial_completion_pr_number, :integer,
      comment: "Merged pull request correlated with the latest partial-completion assessment." unless column_exists?(:issues, :partial_completion_pr_number)
    add_column :issues, :partial_completion_reason, :text,
      comment: "Operator-visible evidence for the latest partial-completion assessment." unless column_exists?(:issues, :partial_completion_reason)
    add_index :issues, :partial_completion_at, where: "partial_completion_at IS NOT NULL", algorithm: :concurrently unless index_exists?(:issues, :partial_completion_at)
  end

  def down
    remove_index :issues, :partial_completion_at, algorithm: :concurrently, if_exists: true
    remove_column :issues, :partial_completion_reason if column_exists?(:issues, :partial_completion_reason)
    remove_column :issues, :partial_completion_pr_number if column_exists?(:issues, :partial_completion_pr_number)
    remove_column :issues, :partial_completion_at if column_exists?(:issues, :partial_completion_at)
  end
end
