# frozen_string_literal: true

class AddProjectsCountToGithubTokens < ActiveRecord::Migration[8.1]
  def up
    add_column :github_tokens, :projects_count, :integer, default: 0, null: false

    execute <<~SQL
      UPDATE github_tokens
      SET projects_count = sub.project_count
      FROM (
        SELECT github_token_id, COUNT(*) AS project_count
        FROM projects
        GROUP BY github_token_id
      ) AS sub
      WHERE github_tokens.id = sub.github_token_id
    SQL
  end

  def down
    remove_column :github_tokens, :projects_count
  end
end
