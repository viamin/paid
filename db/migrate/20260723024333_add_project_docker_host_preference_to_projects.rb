# frozen_string_literal: true

class AddProjectDockerHostPreferenceToProjects < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:projects, :preferred_docker_host_identifier)

    add_column :projects, :preferred_docker_host_identifier, :string,
      comment: "Optional project-level Docker host preference overriding the account default for manual placement."
  end
end
