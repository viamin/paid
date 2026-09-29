# frozen_string_literal: true

class AddUpstreamPullRequestTargetToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :upstream_full_name, :string,
      comment: "Repository that receives cross-repository pull requests when pr_target is upstream"
    add_column :projects, :pr_target, :string, null: false, default: "fork",
      comment: "Pull request destination: fork or upstream"
  end
end
