# frozen_string_literal: true

class CreateQualityMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :quality_metrics do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :prompt_version, foreign_key: { on_delete: :nullify }
      t.decimal :quality_score, precision: 4, scale: 2
      t.boolean :pr_merged
      t.boolean :ci_passed
      t.integer :human_vote
      t.integer :iterations_to_complete
      t.integer :lint_errors, default: 0, null: false
      t.integer :test_failures, default: 0, null: false
      t.integer :files_changed
      t.integer :lines_added
      t.integer :lines_removed
      t.integer :review_comments_count, default: 0, null: false
      t.integer :time_to_first_review_seconds
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :quality_metrics, :agent_run_id, unique: true
    add_index :quality_metrics, :quality_score
    add_index :quality_metrics, :created_at
  end
end
