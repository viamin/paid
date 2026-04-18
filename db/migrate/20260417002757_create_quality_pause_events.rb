# frozen_string_literal: true

class CreateQualityPauseEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_pause_events do |t|
      t.references :project, null: false, foreign_key: true
      t.references :agent_run, foreign_key: true
      t.string :event_type, null: false, limit: 20
      t.decimal :composite_score, precision: 5, scale: 4
      t.decimal :threshold, precision: 5, scale: 4
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :quality_pause_events, [ :project_id, :created_at ]
  end
end
