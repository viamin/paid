# frozen_string_literal: true

class CreateQualityThresholds < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_thresholds do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, foreign_key: true
      t.string :metric_type, null: false, limit: 50
      t.string :goal_type, null: false, limit: 50
      t.decimal :min_value, precision: 5, scale: 4, null: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :quality_thresholds, [ :account_id, :metric_type, :goal_type ],
      unique: true,
      where: "project_id IS NULL",
      name: "index_quality_thresholds_on_account_defaults"
    add_index :quality_thresholds, [ :project_id, :metric_type, :goal_type ],
      unique: true,
      where: "project_id IS NOT NULL",
      name: "index_quality_thresholds_on_project_overrides"
  end
end
