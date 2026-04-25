# frozen_string_literal: true

class CreateKnowledgeUsageStats < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_usage_stats do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.references :project, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.string :artifact_type, null: false, limit: 100
      t.string :goal, null: false, limit: 50
      t.string :context_type, null: false, limit: 50
      t.integer :artifact_count, default: 0, null: false
      t.integer :chunk_count, default: 0, null: false
      t.integer :token_count, default: 0, null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :knowledge_usage_stats,
      [ :agent_run_id, :artifact_type, :context_type ],
      unique: true,
      name: :idx_knowledge_usage_stats_unique

    add_index :knowledge_usage_stats, [ :project_id, :created_at ]
    add_index :knowledge_usage_stats, [ :artifact_type, :goal ]
  end
end
