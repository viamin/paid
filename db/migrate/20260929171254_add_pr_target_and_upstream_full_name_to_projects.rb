# frozen_string_literal: true

# Adds the open-source / upstream PR target settings from issue #4076.
# @spec PR-TARGET-001
class AddPrTargetAndUpstreamFullNameToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:projects, :pr_target)
      add_column :projects, :pr_target, :string, default: "own_repo", null: false,
        comment: "PR target for the project: own_repo (default) or upstream."
    end
    unless column_exists?(:projects, :upstream_full_name)
      add_column :projects, :upstream_full_name, :string,
        comment: "owner/repo of the upstream repository where PRs are opened when pr_target=upstream."
    end
  end
end
