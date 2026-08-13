# frozen_string_literal: true

class AddGinIndexOnLabelsForOpenIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :issues, :labels,
      name: "index_issues_on_labels_gin_open_issues",
      where: "(is_pull_request = false AND github_state = 'open')",
      using: :gin,
      algorithm: :concurrently
  end
end
