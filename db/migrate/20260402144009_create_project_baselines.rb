# frozen_string_literal: true

class CreateProjectBaselines < ActiveRecord::Migration[8.1]
  def change
    create_table :project_baselines do |t|
      t.references :project, null: false, foreign_key: true
      t.string :metric_name, limit: 50, null: false
      t.float :mean, null: false, default: 0.0
      t.float :standard_deviation, null: false, default: 0.0
      t.integer :sample_count, null: false, default: 0
      t.float :p95, null: false, default: 0.0
      t.datetime :last_calculated_at

      t.timestamps
    end

    add_index :project_baselines, [ :project_id, :metric_name ], unique: true
  end
end
