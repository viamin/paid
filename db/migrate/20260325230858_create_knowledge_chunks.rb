# frozen_string_literal: true

class CreateKnowledgeChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_chunks, id: :uuid do |t|
      t.references :knowledge_artifact, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: true
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
    add_index :knowledge_chunks, :content_hash
  end
end
