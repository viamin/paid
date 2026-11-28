class RemoveRedundantProjectVersionsProjectIndex < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  REDUNDANT_INDEX = "index_project_versions_on_project_id"

  def up
    remove_index :project_versions, name: REDUNDANT_INDEX, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :project_versions, :project_id,
      name: REDUNDANT_INDEX, algorithm: :concurrently, if_not_exists: true
  end
end
