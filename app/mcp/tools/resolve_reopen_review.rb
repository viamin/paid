# frozen_string_literal: true

module Tools
  # @spec ISSUE-REOPEN-REVIEW-005
  class ResolveReopenReview < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "resolve_reopen_review"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.description
      "Record a revision-bound decision that a reopened issue may resume normal admission. " \
        "Requires the current GitHub revision, a specific validation reason, and confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, issue_id: { type: "integer" }, reason: { type: "string" },
          revision: { type: "string" }, confirmed: { type: "boolean" }
        }, required: %w[project_id issue_id reason revision confirmed]
      }
    end

    def perform(project_id:, issue_id:, reason:, revision:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to resolve reopen review" unless confirmed

      issue = project_for(project_id).issues.find(issue_id)
      result = Issues::ResolveReopenReview.call(issue:, actor: current_user, reason:, revision:)
      raise ArgumentError, result.message unless result.success?

      { issue_id: issue.id, status: issue.reload.paid_state }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
