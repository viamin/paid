# frozen_string_literal: true

module Tools
  # @spec APPLE-RESULT-006
  class StopAppleVerification < BaseTool
    include AppleVerificationToolSupport

    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "stop_apple_verification"
    def self.write_operation? = true

    def self.description
      "Cancel the acting agent run's own active Apple verification attempt. Requires explicit confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project whose Apple verification attempt runs" },
          agent_run_id: { type: "integer", description: "The acting agent run" },
          attempt_id: { type: "integer", description: "The attempt to cancel" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id agent_run_id attempt_id confirmed]
      }
    end

    def perform(project_id:, agent_run_id:, attempt_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to stop Apple verification" unless confirmed

      with_agent_tool_errors do
        AppleVerification::AgentTools.stop_apple_verification(
          project: project_for(project_id),
          agent_run: agent_run_for(project_id, agent_run_id),
          attempt_id: attempt_id
        )
      end
    end
  end
end
