# frozen_string_literal: true

class AddGinIndexOnIssuesLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :issues, :labels,
      using: :gin,
      where: "is_pull_request = true AND github_state = 'open'",
      name: "index_issues_on_labels_gin_open_prs",
      algorithm: :concurrently
  end
end
