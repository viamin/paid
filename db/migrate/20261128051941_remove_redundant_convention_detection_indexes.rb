# frozen_string_literal: true

class RemoveRedundantConventionDetectionIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-018
  def up
    verify_override_coverer!
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

  private

  def verify_override_coverer!
    indexes = connection.indexes(:project_convention_overrides)
    return unless indexes.any? { |index| index.name == "index_project_convention_overrides_on_project_id" }

    coverer = indexes.find { |index| index.name == "index_project_convention_overrides_on_project_id_and_key" }
    unless coverer&.unique && coverer.valid? && coverer.columns == %w[project_id key] && coverer.where.nil?
      raise ActiveRecord::IrreversibleMigration, "Valid unique override covering index (project_id, key) is required"
    end
  end
end
