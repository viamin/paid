# frozen_string_literal: true

class AddIndexToKnowledgeArtifactsOnProjectStatusType < ActiveRecord::Migration[8.1]
  def change
    add_index :knowledge_artifacts,
              %i[project_id status artifact_type],
              name: "idx_knowledge_artifacts_on_project_status_type",
              comment: "Covers GROUP BY artifact_type WHERE project_id AND status for project show page artifact counts"
  end
end
