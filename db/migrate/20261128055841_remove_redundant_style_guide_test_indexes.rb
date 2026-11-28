# frozen_string_literal: true

class RemoveRedundantStyleGuideTestIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-019
  def up
    remove_index :style_guide_ab_test_assignments, name: "idx_on_style_guide_ab_test_id_653b807c99", algorithm: :concurrently, if_exists: true
    remove_index :style_guide_ab_test_variants, name: "index_style_guide_ab_test_variants_on_style_guide_ab_test_id", algorithm: :concurrently, if_exists: true
    remove_index :style_guide_ab_tests, name: "index_style_guide_ab_tests_on_style_guide_id", algorithm: :concurrently, if_exists: true
    remove_index :style_guide_versions, name: "index_style_guide_versions_on_style_guide_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :style_guide_ab_test_assignments, :style_guide_ab_test_id, name: "idx_on_style_guide_ab_test_id_653b807c99", algorithm: :concurrently, if_not_exists: true
    add_index :style_guide_ab_test_variants, :style_guide_ab_test_id, algorithm: :concurrently, if_not_exists: true
    add_index :style_guide_ab_tests, :style_guide_id, algorithm: :concurrently, if_not_exists: true
    add_index :style_guide_versions, :style_guide_id, algorithm: :concurrently, if_not_exists: true
  end
end
