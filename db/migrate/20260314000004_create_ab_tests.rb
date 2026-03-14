# frozen_string_literal: true

class CreateAbTests < ActiveRecord::Migration[8.1]
  def change
    create_table :ab_tests do |t|
      t.references :prompt, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.text :description
      t.string :status, limit: 20, default: "draft", null: false
      t.integer :traffic_percentage, default: 100, null: false
      t.integer :min_sample_size, default: 30, null: false
      t.decimal :confidence_level, precision: 4, scale: 2
      t.bigint :winner_variant_id
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :ab_tests, :status
    add_index :ab_tests, [ :prompt_id, :status ]

    create_table :ab_test_variants do |t|
      t.references :ab_test, null: false, foreign_key: { on_delete: :cascade }
      t.references :prompt_version, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :weight, default: 50, null: false
      t.integer :sample_count, default: 0, null: false
      t.decimal :avg_quality_score, precision: 4, scale: 2
      t.decimal :total_quality_score, precision: 10, scale: 2, default: 0, null: false

      t.timestamps
    end

    add_index :ab_test_variants, [ :ab_test_id, :name ], unique: true

    add_foreign_key :ab_tests, :ab_test_variants, column: :winner_variant_id, on_delete: :nullify
  end
end
