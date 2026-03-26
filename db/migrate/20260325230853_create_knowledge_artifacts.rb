# frozen_string_literal: true

class CreateKnowledgeArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_artifacts do |t|
      t.references :collector_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: true
      t.string :artifact_type, limit: 100, null: false
      t.string :scope_path, limit: 1000
      t.string :identifier, limit: 500
      t.text :content
      t.string :content_hash, limit: 64, null: false
      t.jsonb :metadata, default: {}
      t.string :status, limit: 50, null: false, default: "active"

      t.timestamps
    end

    add_index :knowledge_artifacts, [ :project_id, :artifact_type, :identifier ]
    add_index :knowledge_artifacts, :content_hash
    add_index :knowledge_artifacts, :status
  end
end
