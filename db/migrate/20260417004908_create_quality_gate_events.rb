# frozen_string_literal: true

class CreateQualityGateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_gate_events do |t|
      t.references :project, null: false, foreign_key: true
      t.references :quality_gate_threshold, null: false, foreign_key: true
      t.references :quality_metric, null: false, foreign_key: true
      t.string :event_type, null: false, limit: 20
      t.decimal :score_value, precision: 5, scale: 4, null: false
      t.decimal :threshold_value, precision: 5, scale: 4, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :quality_gate_events, [ :project_id, :event_type, :created_at ],
      name: "idx_quality_gate_events_project_type_time"
  end
end
