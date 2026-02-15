# frozen_string_literal: true

class AddGithubCreatorAllowlist < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :allowed_github_usernames, :jsonb, default: [], null: false
    add_column :issues, :github_creator_login, :string

    add_index :issues, :github_creator_login
  end
end
