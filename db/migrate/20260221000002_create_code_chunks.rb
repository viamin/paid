# frozen_string_literal: true

class CreateCodeChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :code_chunks do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :file_path, null: false
      t.string :chunk_type, limit: 50, null: false
      t.string :identifier
      t.text :content, null: false
      t.string :content_hash, limit: 64, null: false
      t.vector :embedding, limit: 1536
      t.integer :start_line
      t.integer :end_line
      t.string :language, limit: 50

      t.timestamps
    end

    add_index :code_chunks, [ :project_id, :file_path, :chunk_type, :identifier ],
      unique: true, name: "index_code_chunks_on_project_file_chunk_identifier"
    add_index :code_chunks, :content_hash
  end
end
