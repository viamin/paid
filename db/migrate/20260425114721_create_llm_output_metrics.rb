# frozen_string_literal: true

class CreateLlmOutputMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :llm_output_metrics do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :output_type, null: false, limit: 30
      t.string :prompt_slug, null: false, limit: 100
      t.bigint :source_id, null: false
      t.string :source_type, null: false, limit: 30
      t.references :prompt_version, foreign_key: { on_delete: :nullify }
      t.jsonb :scores, default: {}, null: false
      t.decimal :composite_score, precision: 5, scale: 4
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :llm_output_metrics, [ :source_type, :source_id ]
    add_index :llm_output_metrics, :output_type
    add_index :llm_output_metrics, [ :project_id, :output_type, :created_at ],
      name: "idx_llm_output_metrics_project_type_time"
    add_index :llm_output_metrics, [ :prompt_slug, :prompt_version_id ],
      name: "idx_llm_output_metrics_slug_version"
  end
end
