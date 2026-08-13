# frozen_string_literal: true

class AddAccessibleRepositoriesToGithubTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :github_tokens, :accessible_repositories, :jsonb, default: [], null: false
    add_column :github_tokens, :repositories_synced_at, :datetime
  end
end
