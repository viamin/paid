# frozen_string_literal: true

class RemoveRedundantStyleGuideExposureIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-017
  def up
    remove_index :style_guide_run_exposures, name: "index_style_guide_run_exposures_on_agent_run_id", algorithm: :concurrently, if_exists: true
    remove_index :style_guide_run_exposures, name: "index_style_guide_run_exposures_on_assignment_id", algorithm: :concurrently, if_exists: true
    remove_index :style_guide_run_exposures, name: "index_style_guide_run_exposures_on_style_guide_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :style_guide_run_exposures, :agent_run_id, algorithm: :concurrently, if_not_exists: true
    add_index :style_guide_run_exposures, :style_guide_ab_test_assignment_id,
      name: "index_style_guide_run_exposures_on_assignment_id", algorithm: :concurrently, if_not_exists: true
    add_index :style_guide_run_exposures, :style_guide_id, algorithm: :concurrently, if_not_exists: true
  end
end
