# frozen_string_literal: true

class RemoveRedundantProjectConventionRecommendationsProjectIndex < ActiveRecord::Migration[8.1]
  REDUNDANT_INDEX = "index_project_convention_recommendations_on_project_id"

  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-014
  def up
    remove_index :project_convention_recommendations,
      name: REDUNDANT_INDEX,
      algorithm: :concurrently,
      if_exists: true
  end

  def down
    add_index :project_convention_recommendations,
      :project_id,
      name: REDUNDANT_INDEX,
      algorithm: :concurrently,
      if_not_exists: true
  end
end
