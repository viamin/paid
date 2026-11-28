# frozen_string_literal: true

class RemoveRedundantProjectServiceContainersProjectIndex < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  INDEX_NAME = "index_project_service_containers_on_project_id"

  def up
    remove_index :project_service_containers, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :project_service_containers, :project_id, name: INDEX_NAME,
      algorithm: :concurrently, if_not_exists: true
  end
end
