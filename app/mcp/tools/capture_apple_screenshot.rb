# frozen_string_literal: true

module Tools
  # @spec APPLE-RESULT-006
  class CaptureAppleScreenshot < BaseTool
    include AppleVerificationToolSupport

    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "capture_apple_screenshot"
    def self.write_operation? = true

    def self.description
      "Queue an Apple verification attempt that captures a screenshot declared by the workflow revision. " \
        "Requires explicit confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project whose Apple verification workflow runs" },
          agent_run_id: { type: "integer", description: "The acting agent run" },
          capture_id: { type: "string", description: "Capture identifier declared by the workflow revision" },
          bundle_digest: { type: "string", description: "sha256:<64 hex> digest of the uncommitted workspace bundle" },
          commit_sha: { type: "string", description: "40-character hex identity of the committed source to verify" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id agent_run_id capture_id confirmed]
      }
    end

    def perform(project_id:, agent_run_id:, capture_id:, bundle_digest: nil, commit_sha: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to capture an Apple screenshot" unless confirmed

      with_agent_tool_errors do
        AppleVerification::AgentTools.capture_apple_screenshot(
          project: project_for(project_id),
          agent_run: agent_run_for(project_id, agent_run_id),
          capture_id: capture_id,
          bundle_digest: bundle_digest,
          commit_sha: commit_sha
        )
      end
    end
  end
end
