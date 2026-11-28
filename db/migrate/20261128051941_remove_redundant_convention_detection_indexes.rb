# frozen_string_literal: true

class RemoveRedundantConventionDetectionIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-018
  def up
    remove_index :project_convention_overrides, name: "index_project_convention_overrides_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :project_convention_recommendations, name: "index_project_convention_recommendations_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :project_convention_detections, name: "index_project_convention_detections_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :project_convention_detections, name: "index_project_convention_detections_on_project_version_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :project_convention_overrides, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :project_convention_recommendations, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :project_convention_detections, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :project_convention_detections, :project_version_id, algorithm: :concurrently, if_not_exists: true
  end
end
