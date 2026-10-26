# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    # @spec LAYERED-VERIFY-014
    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.mcp_available? = true

    def self.description
      "Preview or dispatch a bounded, issue-less layered-verification audit. " \
        "Preview resolves scope, sources, target revision, and budget; dispatch requires confirmed=true."
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          obligation_ids: { type: "array", items: { type: "integer" } },
          sources: { type: "array", items: { type: "string" } },
          target_revision: { type: "string" },
          budget: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[project_id obligation_ids sources target_revision budget]
      }
    end

    def perform(project_id:, obligation_ids:, sources:, target_revision:, budget:, confirmed: false)
      request = request_for(project_id:, obligation_ids:, sources:, target_revision:, budget:)
      result = confirmed ? request.call : request.preview
      audit_response(result, dispatched: confirmed)
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    def request_for(project_id:, obligation_ids:, sources:, target_revision:, budget:)
      LayeredVerification::Audits::Request.new(
        project: project_for(project_id), actor: current_user, obligation_ids:, sources:, target_revision:, budget:
      )
    end

    def audit_response(result, dispatched:)
      {
        dispatched:,
        agent_run_id: result.run&.id,
        status: result.run&.status,
        scope: result.scope,
        sources: result.sources,
        target_revision: result.target_revision,
        budget: result.budget
      }
    end
  end
end
