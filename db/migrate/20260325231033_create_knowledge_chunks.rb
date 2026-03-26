# frozen_string_literal: true

class CreateKnowledgeChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_chunks, id: :uuid do |t|
      t.bigint :knowledge_artifact_id, null: false
      t.bigint :project_id, null: false
      t.string :chunk_type, limit: 50, null: false
      t.text :content, null: false
      t.string :content_hash, limit: 64, null: false
      t.string :embedding_model, limit: 100
      t.jsonb :scope_tags, default: []
      t.string :status, limit: 50, null: false, default: "active"
      t.integer :sequence, default: 0

      t.timestamps
    end

    add_index :knowledge_chunks, [ :project_id, :status ]
    add_index :knowledge_chunks, :knowledge_artifact_id
    add_index :knowledge_chunks, :content_hash
    add_foreign_key :knowledge_chunks, :knowledge_artifacts, on_delete: :cascade
    add_foreign_key :knowledge_chunks, :projects
  end
end
