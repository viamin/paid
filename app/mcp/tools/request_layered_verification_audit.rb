# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Show and, when confirmed, queue a bounded report-only layered-verification audit. " \
        "It never repairs code or canonical intent."
    end

    def self.available_to?(user:)
      user.present? && policy_allows?(user:, record: Project.new(account: user.account), query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.available_for_chat?(user:, session:)
      available_to?(user:) && session&.project_id.present?
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          source_references: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
          budget_tokens: { type: "integer" }, confirmed: { type: "boolean" }
        },
        required: %w[project_id obligation_ids source_references target_revision budget_tokens confirmed]
      }
    end

    def perform(project_id:, obligation_ids:, source_references:, target_revision:, budget_tokens:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an audit" unless confirmed

      result = LayeredVerification::Audits::Request.call(
        project: project_for(project_id), actor: current_user, obligation_ids:, source_references:, target_revision:, budget_tokens:, trigger: "mcp"
      )
      { id: result.run.id, status: result.run.status, goal: result.run.goal, dispatch: result.dispatch }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
