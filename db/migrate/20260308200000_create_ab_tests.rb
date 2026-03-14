# frozen_string_literal: true

class CreateAbTests < ActiveRecord::Migration[8.1]
  def change
    create_table :ab_tests do |t|
      t.references :prompt, null: false, foreign_key: { on_delete: :cascade }

      t.string :name, limit: 255, null: false
      t.text :description
      t.string :status, limit: 50, default: "draft", null: false

      t.bigint :control_version_id, null: false
      t.bigint :winner_variant_id

      t.integer :min_samples_per_variant, default: 30, null: false
      t.decimal :confidence_threshold, precision: 4, scale: 2, default: 0.95, null: false

      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_foreign_key :ab_tests, :prompt_versions, column: :control_version_id, on_delete: :restrict

    add_index :ab_tests, :status
    add_index :ab_tests, :control_version_id
    add_index :ab_tests, [ :prompt_id, :status ], name: "index_ab_tests_on_prompt_id_and_status"

    create_table :ab_test_variants do |t|
      t.references :ab_test, null: false, foreign_key: { on_delete: :cascade }
      t.references :prompt_version, null: false, foreign_key: { on_delete: :restrict }

      t.boolean :is_control, default: false, null: false
      t.integer :sample_count, default: 0, null: false
      t.decimal :total_quality_score, precision: 10, scale: 4, default: 0, null: false
      t.decimal :avg_quality_score, precision: 5, scale: 4

      t.timestamps
    end

    add_index :ab_test_variants, [ :ab_test_id, :is_control ], name: "index_ab_test_variants_on_test_and_control"

    add_index :ab_test_variants, :ab_test_id,
      unique: true,
      where: "is_control = true",
      name: "index_ab_test_variants_on_control_per_test"

    add_index :ab_test_variants, [ :ab_test_id, :prompt_version_id ],
      unique: true,
      name: "index_ab_test_variants_on_test_and_prompt_version"

    # Add winner_variant FK after ab_test_variants table exists
    add_foreign_key :ab_tests, :ab_test_variants, column: :winner_variant_id, on_delete: :nullify

    create_table :ab_test_assignments do |t|
      t.references :ab_test, null: false, foreign_key: { on_delete: :cascade }
      t.references :ab_test_variant, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }

      t.decimal :quality_score, precision: 5, scale: 4

      t.datetime :created_at, null: false
    end

    add_index :ab_test_assignments, [ :ab_test_id, :agent_run_id ],
      unique: true, name: "index_ab_test_assignments_unique"
  end
end
