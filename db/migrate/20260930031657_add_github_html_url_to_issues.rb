# frozen_string_literal: true

class AddGithubHtmlUrlToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :github_html_url, :string,
      comment: "Canonical GitHub HTML URL captured from the sync payload; stable across repository retargeting",
      if_not_exists: true

    safety_assured do
      execute <<~SQL.squish
        UPDATE issues
        SET github_html_url = agent_runs.pull_request_url
        FROM agent_runs
        WHERE issues.source = 'upstream_pull_request'
          AND issues.project_id = agent_runs.project_id
          AND issues.github_number = agent_runs.pull_request_number
          AND agent_runs.pull_request_url IS NOT NULL
          AND issues.github_html_url IS NULL
      SQL

      execute <<~SQL.squish
        UPDATE issues
        SET github_html_url = CONCAT(
          'https://github.com/', projects.owner, '/', projects.repo, '/pull/', issues.github_number
        )
        FROM projects
        WHERE issues.project_id = projects.id
          AND issues.source = 'github'
          AND issues.is_pull_request = TRUE
          AND issues.github_html_url IS NULL
      SQL
    end
  end

  def down
    remove_column :issues, :github_html_url, if_exists: true
  end
end
