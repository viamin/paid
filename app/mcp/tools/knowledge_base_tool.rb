# frozen_string_literal: true

module Tools
  # @spec KNOWLEDGE-AGENT-TOOLS-005
  class KnowledgeBaseTool < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def knowledge_uri(project:, artifact_type:, artifact_id:)
      "knowledge://#{project.id}/#{artifact_type}/#{artifact_id}"
    end
  end
end
