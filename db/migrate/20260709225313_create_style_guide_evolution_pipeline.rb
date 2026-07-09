# frozen_string_literal: true

class CreateStyleGuideEvolutionPipeline < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  class MigrationStyleGuide < ApplicationRecord
    self.table_name = "style_guides"
  end

  class MigrationStyleGuideVersion < ApplicationRecord
    self.table_name = "style_guide_versions"
  end

  def change
    create_table :style_guide_versions do |t|
      t.references :style_guide, null: false, foreign_key: { on_delete: :cascade }
      t.integer :version, null: false
      t.text :raw_content, null: false
      t.text :compressed_content
      t.jsonb :compression_metadata, null: false, default: {}
      t.text :change_notes
      t.string :created_by, limit: 50
      t.references :created_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :parent_version, null: true, foreign_key: { to_table: :style_guide_versions, on_delete: :nullify }
      t.string :review_status, limit: 20
      t.text :review_notes
      t.datetime :reviewed_at
      t.references :reviewed_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.integer :usage_count, null: false, default: 0
      t.decimal :avg_quality_score, precision: 5, scale: 4
      t.datetime :retired_at
      t.string :idempotency_key
      t.timestamps
    end
    add_index :style_guide_versions, [ :style_guide_id, :version ], unique: true
    add_index :style_guide_versions, [ :style_guide_id, :idempotency_key ],
      unique: true, where: "idempotency_key IS NOT NULL"
    add_index :style_guide_versions, :retired_at
    add_index :style_guide_versions, [ :style_guide_id, :review_status ]

    add_column :style_guides, :current_version_id, :bigint
    add_index :style_guides, :current_version_id, algorithm: :concurrently

    create_table :style_guide_ab_tests do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :style_guide, null: false, foreign_key: { on_delete: :cascade }
      t.references :control_version, null: false, foreign_key: { to_table: :style_guide_versions, on_delete: :restrict }
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "draft"
      t.integer :min_samples_per_variant, null: false, default: 30
      t.decimal :confidence_threshold, null: false, default: 0.95
      t.jsonb :cached_analysis
      t.string :analysis_samples_key
      t.string :idempotency_key
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :style_guide_ab_tests, :status
    add_index :style_guide_ab_tests, [ :account_id ], unique: true,
      where: "((status)::text = 'running'::text)", name: "index_style_guide_ab_tests_one_running_per_account"
    add_index :style_guide_ab_tests, [ :style_guide_id, :status ]
    add_index :style_guide_ab_tests, [ :style_guide_id, :idempotency_key ],
      unique: true, where: "idempotency_key IS NOT NULL"

    create_table :style_guide_ab_test_variants do |t|
      t.references :style_guide_ab_test, null: false, foreign_key: { on_delete: :cascade }
      t.references :style_guide_version, null: false, foreign_key: { on_delete: :restrict }
      t.boolean :is_control, null: false, default: false
      t.integer :sample_count, null: false, default: 0
      t.decimal :total_quality_score, precision: 10, scale: 4, null: false, default: 0.0
      t.decimal :avg_quality_score, precision: 5, scale: 4
      t.timestamps
    end
    add_index :style_guide_ab_test_variants, [ :style_guide_ab_test_id, :style_guide_version_id ],
      unique: true, name: "index_style_guide_ab_test_variants_on_test_and_version"
    add_index :style_guide_ab_test_variants, [ :style_guide_ab_test_id ],
      unique: true, where: "(is_control = true)", name: "index_style_guide_ab_test_variants_on_control_per_test"

    add_column :style_guide_ab_tests, :winner_variant_id, :bigint
    add_index :style_guide_ab_tests, :winner_variant_id, algorithm: :concurrently

    create_table :style_guide_ab_test_assignments do |t|
      t.references :style_guide_ab_test, null: false, foreign_key: { on_delete: :cascade }
      t.references :style_guide_ab_test_variant, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.decimal :quality_score, precision: 5, scale: 4
      t.timestamps
    end
    add_index :style_guide_ab_test_assignments, [ :style_guide_ab_test_id, :agent_run_id ],
      unique: true, name: "index_style_guide_ab_test_assignments_unique"

    create_table :style_guide_run_exposures do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :style_guide, null: true, foreign_key: { on_delete: :nullify }
      t.references :style_guide_version, null: false, foreign_key: { on_delete: :restrict }
      t.references :style_guide_ab_test_assignment, null: true,
        foreign_key: { on_delete: :nullify }
      t.string :guide_name, null: false
      t.string :source_scope, limit: 20, null: false
      t.integer :position, null: false
      t.string :injected_via, limit: 50, null: false
      t.text :injected_content
      t.timestamps
    end
    add_index :style_guide_run_exposures, [ :agent_run_id, :guide_name ],
      unique: true, name: "index_style_guide_run_exposures_on_run_and_name"
    add_index :style_guide_run_exposures, [ :style_guide_id, :created_at ]
    add_index :style_guide_run_exposures, :style_guide_ab_test_assignment_id,
      name: "index_style_guide_run_exposures_on_assignment_id"

    reversible do |dir|
      dir.up { backfill_style_guide_versions! }
    end
  end

  private

  def backfill_style_guide_versions!
    MigrationStyleGuide.reset_column_information
    MigrationStyleGuideVersion.reset_column_information

    MigrationStyleGuide.find_each do |style_guide|
      version = MigrationStyleGuideVersion.create!(
        style_guide_id: style_guide.id,
        version: 1,
        raw_content: style_guide.raw_content,
        compressed_content: style_guide.compressed_content,
        compression_metadata: style_guide.compression_metadata || {},
        created_by: "backfill",
        change_notes: "Initial snapshot backfilled from mutable style_guide row"
      )
      style_guide.update_columns(current_version_id: version.id)
    end
  end
end
