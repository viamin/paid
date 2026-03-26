# frozen_string_literal: true

class CreateKnowledgeArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_artifacts do |t|
      t.bigint :collector_run_id, null: false
      t.bigint :project_id, null: false
      t.string :artifact_type, limit: 100, null: false
      t.string :scope_path, limit: 1000
      t.string :identifier, limit: 500
      t.text :content
      t.string :content_hash, limit: 64, null: false
      t.jsonb :metadata, default: {}
      t.string :status, limit: 50, null: false, default: "active"

      t.timestamps
    end

    add_index :knowledge_artifacts, [ :project_id, :artifact_type, :identifier ], name: "idx_knowledge_artifacts_project_type_identifier"
    add_index :knowledge_artifacts, :collector_run_id
    add_index :knowledge_artifacts, :content_hash
    add_index :knowledge_artifacts, :status
    add_foreign_key :knowledge_artifacts, :collector_runs, on_delete: :cascade
    add_foreign_key :knowledge_artifacts, :projects
  end
end
