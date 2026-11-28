# frozen_string_literal: true

class RemoveRedundantProjectMembershipIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-016
  def up
    remove_index :project_memberships, name: "index_project_memberships_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :project_memberships, name: "index_project_memberships_on_user_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :project_memberships, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :project_memberships, :user_id, algorithm: :concurrently, if_not_exists: true
  end
end
