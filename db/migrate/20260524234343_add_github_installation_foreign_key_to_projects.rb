# frozen_string_literal: true

class AddGithubInstallationForeignKeyToProjects < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :projects, :github_installations, validate: false
  end
end
