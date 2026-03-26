# frozen_string_literal: true

class AddCompositeIndexesToKnowledgeArtifacts < ActiveRecord::Migration[8.1]
  def change
    remove_index :knowledge_artifacts, [ :project_id, :artifact_type, :identifier ]

    add_index :knowledge_artifacts,
      [ :project_id, :artifact_type, :scope_path, :identifier, :status ],
      name: "idx_knowledge_artifacts_on_project_type_scope_identifier_status"

    add_index :knowledge_artifacts,
      [ :project_id, :artifact_type, :scope_path, :identifier ],
      unique: true,
      where: "status = 'active'",
      name: "idx_knowledge_artifacts_active_unique"
  end
end
