# frozen_string_literal: true

module Tools
  # @spec APPLE-RESULT-006
  class VerifyAppleProject < BaseTool
    include AppleVerificationToolSupport

    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "verify_apple_project"
    def self.write_operation? = true

    def self.description
      "Queue an Apple verification attempt for the acting agent run, from an uncommitted workspace bundle digest " \
        "(draft workflow at the agent_iteration gate) or a committed revision (approved workflow). " \
        "Requires explicit confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project whose Apple verification workflow runs" },
          agent_run_id: { type: "integer", description: "The acting agent run" },
          bundle_digest: { type: "string", description: "sha256:<64 hex> digest of the uncommitted workspace bundle" },
          commit_sha: { type: "string", description: "40-character hex identity of the committed source to verify" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id agent_run_id confirmed]
      }
    end

    def perform(project_id:, agent_run_id:, bundle_digest: nil, commit_sha: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to queue Apple verification" unless confirmed

      with_agent_tool_errors do
        AppleVerification::AgentTools.verify_apple_project(
          project: project_for(project_id),
          agent_run: agent_run_for(project_id, agent_run_id),
          bundle_digest: bundle_digest,
          commit_sha: commit_sha
        )
      end
    end
  end
end
