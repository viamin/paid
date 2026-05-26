# frozen_string_literal: true

class AddGithubInstallationToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :projects, :github_installation, null: true,
                  comment: "GitHub App installation for repo auth; mutually exclusive with github_token_id",
                  index: { algorithm: :concurrently }

    change_column_null :projects, :github_token_id, true
  end
end
