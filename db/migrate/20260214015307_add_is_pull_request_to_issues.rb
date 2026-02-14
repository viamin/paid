class AddIsPullRequestToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :is_pull_request, :boolean, default: false, null: false
  end
end
