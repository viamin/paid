# frozen_string_literal: true

class AddProjectsCountToGithubTokens < ActiveRecord::Migration[8.1]
  def up
    add_column :github_tokens, :projects_count, :integer, default: 0, null: false

    GithubToken.reset_column_information
    GithubToken.find_each do |token|
      GithubToken.reset_counters(token.id, :projects)
    end
  end

  def down
    remove_column :github_tokens, :projects_count
  end
end
