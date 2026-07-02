# frozen_string_literal: true

module Tools
  class GetIntent < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "get_intent"

    def self.description
      "Get a specific change intent record (CIR) with full directional details."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          intent_id: { type: "integer", description: "The change intent record ID" }
        },
        required: %w[project_id intent_id]
      }
    end

    def perform(project_id:, intent_id:)
      project = project_for(project_id)
      intent = project.change_intents.find(intent_id)

      {
        id: intent.id,
        project_id: intent.project_id,
        issue_id: intent.issue_id,
        chat_session_id: intent.chat_session_id,
        superseded_by_id: intent.superseded_by_id,
        status: intent.status,
        title: intent.title,
        intent: intent.intent,
        behavior: intent.behavior,
        constraints: intent.constraints,
        decisions_made: intent.decisions_made,
        created_at: intent.created_at,
        updated_at: intent.updated_at
      }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
