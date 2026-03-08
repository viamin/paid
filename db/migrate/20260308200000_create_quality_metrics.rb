# frozen_string_literal: true

class CreateQualityMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_metrics do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :prompt_version, foreign_key: { on_delete: :nullify }
      t.string :metric_type, limit: 20, null: false
      t.jsonb :scores, default: {}, null: false
      t.decimal :composite_score, precision: 5, scale: 4
      t.string :feedback_source, limit: 50
      t.jsonb :metadata, default: {}, null: false
      t.datetime :created_at, null: false
    end

    add_index :quality_metrics, :metric_type
    add_index :quality_metrics, :composite_score
    add_index :quality_metrics, :created_at
    add_index :quality_metrics, [ :prompt_version_id, :created_at ],
      name: "index_quality_metrics_on_prompt_version_and_created_at"
    add_index :quality_metrics, [ :agent_run_id, :metric_type ],
      name: "index_quality_metrics_on_agent_run_and_type",
      unique: true
  end
end
