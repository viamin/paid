class AddAutoMergeHeadShaToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :auto_merge_head_sha, :string, limit: 40,
      comment: "PR HEAD commit SHA for the persisted auto-merge blocker assessment."
  end
end
