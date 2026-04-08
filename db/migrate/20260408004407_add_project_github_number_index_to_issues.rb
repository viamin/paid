class AddProjectGithubNumberIndexToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Supports the EXISTS subqueries in AgentRun::QUEUE_PRIORITY_SQL, which
  # look up issues / PRs by (project_id, github_number) when classifying
  # the priority tier of every queued run. Without this index, queue
  # ordering on large projects degrades to repeated sequential scans.
  def change
    add_index :issues, [ :project_id, :github_number ],
      name: "index_issues_on_project_id_and_github_number",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
