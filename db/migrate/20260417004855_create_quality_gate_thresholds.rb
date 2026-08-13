# frozen_string_literal: true

class CreateQualityGateThresholds < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_gate_thresholds do |t|
      t.references :project, null: false, foreign_key: true
      t.string :metric_key, null: false, limit: 50
      t.decimal :min_threshold, precision: 5, scale: 4
      t.decimal :max_threshold, precision: 5, scale: 4
      t.string :severity, null: false, default: "warning", limit: 20
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :quality_gate_thresholds, [ :project_id, :metric_key ], unique: true
  end
end
