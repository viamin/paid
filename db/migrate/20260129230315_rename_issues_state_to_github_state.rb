# frozen_string_literal: true

class RenameIssuesStateToGithubState < ActiveRecord::Migration[8.1]
  def change
    # Only rename if the old column exists (idempotent migration)
    if column_exists?(:issues, :state) && !column_exists?(:issues, :github_state)
      rename_column :issues, :state, :github_state
    end
  end
end
