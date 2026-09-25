# frozen_string_literal: true

module Tools
  # @spec APPLE-RESULT-006
  class GetAppleVerification < BaseTool
    include AppleVerificationToolSupport

    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "get_apple_verification"

    def self.description
      "Inspect the Apple verification state for a project and agent run: mode, workflow revisions, and the run's " \
        "attempts with failure classification and protected artifact metadata."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project whose Apple verification state is inspected" },
          agent_run_id: { type: "integer", description: "The acting agent run" },
          attempt_id: { type: "integer", description: "Restrict the inspection to one attempt" }
        },
        required: %w[project_id agent_run_id]
      }
    end

    def perform(project_id:, agent_run_id:, attempt_id: nil)
      with_agent_tool_errors do
        AppleVerification::AgentTools.get_apple_verification(
          project: project_for(project_id),
          agent_run: agent_run_for(project_id, agent_run_id),
          attempt_id: attempt_id
        )
      end
    end
  end
end
