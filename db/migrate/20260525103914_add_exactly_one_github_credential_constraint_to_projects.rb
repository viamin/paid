# frozen_string_literal: true

class AddExactlyOneGithubCredentialConstraintToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    safety_assured do
      execute <<-SQL.squish
        ALTER TABLE projects ADD CONSTRAINT chk_projects_exactly_one_github_credential
        CHECK (
          (github_token_id IS NOT NULL AND github_installation_id IS NULL) OR
          (github_token_id IS NULL AND github_installation_id IS NOT NULL)
        ) NOT VALID
      SQL
    end
    validate_constraint :projects, :chk_projects_exactly_one_github_credential
  end

  def down
    remove_check_constraint :projects, :chk_projects_exactly_one_github_credential
  end
end
