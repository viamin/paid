# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    # @spec LAYERED-VERIFY-014
    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.description = "Preview or queue a bounded, issue-less layered-verification audit. It records evidence only and never starts repair."
    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, scope: { type: "array", items: { type: "string" } },
        sources: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
        budget: { type: "integer" }, confirmed: { type: "boolean" }
      }, required: %w[project_id scope sources target_revision budget] }
    end

    def perform(project_id:, scope:, sources:, target_revision:, budget:, confirmed: false)
      request = LayeredVerification::Audits::Request.new(
        project: project_for(project_id), user: current_user, scope:, sources:, target_revision:, budget:, trigger: "mcp"
      )
      return { preview: request.preview.to_h, confirmation_required: true } unless confirmed

      run = request.call
      { id: run.id, status: run.status, goal: run.goal, project_id: run.project_id }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
