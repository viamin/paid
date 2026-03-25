# frozen_string_literal: true

class CreateKnowledgeLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_links do |t|
      t.uuid :source_chunk_id, null: false
      t.uuid :target_chunk_id, null: false
      t.string :link_type, limit: 50, null: false
      t.decimal :weight, precision: 5, scale: 3, default: 1.0
      t.jsonb :metadata, default: {}

      t.datetime :created_at, null: false
    end

    add_index :knowledge_links, [ :source_chunk_id, :target_chunk_id, :link_type ],
      unique: true, name: "index_knowledge_links_on_source_target_type"
    add_index :knowledge_links, :target_chunk_id
    add_index :knowledge_links, :link_type
    add_foreign_key :knowledge_links, :knowledge_chunks, column: :source_chunk_id, on_delete: :cascade
    add_foreign_key :knowledge_links, :knowledge_chunks, column: :target_chunk_id, on_delete: :cascade
  end
end
