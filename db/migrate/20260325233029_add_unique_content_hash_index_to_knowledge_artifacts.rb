# frozen_string_literal: true

class AddUniqueContentHashIndexToKnowledgeArtifacts < ActiveRecord::Migration[8.1]
  def change
    remove_index :knowledge_artifacts, :content_hash
    add_index :knowledge_artifacts, [ :collector_run_id, :content_hash ], unique: true
  end
end
