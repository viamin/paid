# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-015
class ValidateProjectsGithubInstallationForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :projects, :github_installations, column: :github_installation_id
  end
end
