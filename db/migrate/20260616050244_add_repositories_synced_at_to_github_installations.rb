# frozen_string_literal: true

class AddRepositoriesSyncedAtToGithubInstallations < ActiveRecord::Migration[8.1]
  def change
    add_column :github_installations, :repositories_synced_at, :datetime,
      comment: "When accessible_repositories was last refreshed from the GitHub App installation API"
  end
end
