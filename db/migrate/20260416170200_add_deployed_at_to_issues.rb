# frozen_string_literal: true

# Tracks when a pull request was deployed to production. Used by the
# multi-step PR dependency feature so a dependent PR can wait until its
# predecessor has actually shipped, not just merged. Null means the PR
# has not been marked as deployed. Indexed only on open PRs so that
# deployment-blocked dependency checks stay cheap on the hot path.
class AddDeployedAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :deployed_at, :datetime

    add_index :issues, :deployed_at,
              where: "is_pull_request = true",
              name: "idx_issues_deployed_at_on_prs"
  end
end
