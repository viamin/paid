# frozen_string_literal: true

# @spec PROJECT-CREATION-003
# @spec PROJECT-CREATION-011
class AddCreationOriginAndSetupStatusToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:projects, :creation_origin)
      add_column :projects, :creation_origin, :string, null: false, default: "connected",
        comment: "How the project came to be: connected (existing repo) or blank (repo created by Paid)."
    end
    unless column_exists?(:projects, :setup_status)
      add_column :projects, :setup_status, :string,
        comment: "Blank-project bootstrap state: pending, in_progress, or completed. Null when setup is not required."
    end
    unless index_exists?(:projects, :setup_status, name: :index_projects_on_setup_status)
      add_index :projects, :setup_status, name: :index_projects_on_setup_status,
        where: "setup_status IS NOT NULL", algorithm: :concurrently, if_not_exists: true
    end
  end
end
