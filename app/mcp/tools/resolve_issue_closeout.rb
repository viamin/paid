# frozen_string_literal: true

module Tools
  class ResolveIssueCloseout < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "resolve_issue_closeout"
    def self.write_operation? = true
    def self.description = "Resolve a stalled partial closeout as complete against its current evidence. Requires confirmation."
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, issue_id: { type: "integer" }, reason: { type: "string" }, confirmed: { type: "boolean" } }, required: %w[project_id issue_id reason confirmed] }
    end

    def perform(project_id:, issue_id:, reason:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to resolve closeout" unless confirmed

      project = project_for(project_id)
      result = Issues::ResolveCloseout.call(issue: project.issues.find(issue_id), actor: current_user, reason:)
      raise ArgumentError, result.message unless result.success?

      { issue_id: result.issue.id, status: result.issue.paid_state }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
