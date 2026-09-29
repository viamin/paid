# frozen_string_literal: true

class AddPrTargetToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :pr_target, :string,
      default: "own_repo",
      null: false,
      comment: "Where Paid opens pull requests: \"own_repo\" (default) targets the project's own fork; \"upstream\" targets the configured upstream repository (#4076)."
    add_column :projects, :upstream_owner, :string,
      comment: "GitHub owner (login or org) of the upstream repository PRs target when pr_target is \"upstream\". Required for upstream mode."
    add_column :projects, :upstream_repo, :string,
      comment: "GitHub repository name of the upstream repository PRs target when pr_target is \"upstream\". Required for upstream mode."
  end
end
