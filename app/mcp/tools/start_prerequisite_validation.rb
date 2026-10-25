# frozen_string_literal: true

module Tools
  # Starts one bounded execution-evidence validation for a prerequisite owner
  # issue (#4643). Same authorization and services as the Inbox action; the
  # validation row and its job are the durable progress surface.
  # @spec PREREQ-EVIDENCE-002 @spec PREREQ-EVIDENCE-007
  class StartPrerequisiteValidation < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "start_prerequisite_validation"
    def self.write_operation? = true
    def self.description
      "Start one bounded execution-evidence validation for a prerequisite owner issue. Provisions a fresh " \
        "pinned run in the project's isolated execution environment, runs a read-only native analyzer " \
        "(and the allowlisted tool sidecar when the rollout flag and image allowlist permit), records " \
        "stdout/stderr/exit status and cleanup evidence, and links it to the issue without closing it. " \
        "Missing capabilities or authorizations come back as blockers naming the exact authorized action. " \
        "Requires confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_id: { type: "integer", description: "The prerequisite owner issue ID" },
          include_tool_sidecar: { type: "boolean", description: "Include the tool-sidecar interaction check (default true)" },
          analyzer_command: { type: "string", description: "Optional bounded read-only analyzer command (defaults to the agent image scc probe)" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id issue_id confirmed]
      }
    end

    def perform(project_id:, issue_id:, include_tool_sidecar: true, analyzer_command: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to start a prerequisite validation" unless confirmed

      project = project_for(project_id)
      result = Prerequisites::StartValidation.call(
        issue: project.issues.find(issue_id),
        actor: current_user,
        include_tool_sidecar: include_tool_sidecar,
        analyzer_command: analyzer_command
      )
      raise ArgumentError, result.message unless result.success?

      { id: result.validation.id, status: result.validation.status, issue_id: result.validation.issue_id }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
