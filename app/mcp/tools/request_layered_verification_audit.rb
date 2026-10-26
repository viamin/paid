# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Show and, after confirmation, dispatch a bounded report-only layered-verification audit. It never authorizes repair."
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
        revision: { type: "string" }, budget_cents: { type: "integer" }, confirmed: { type: "boolean" }
      }, required: %w[project_id obligation_ids revision budget_cents confirmed] }
    end

    def perform(project_id:, obligation_ids:, revision:, budget_cents:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an audit" unless confirmed

      run = LayeredVerification::Audits::Request.call(
        project: project_for(project_id), actor: current_user, obligation_ids:, revision:, budget_cents:
      )
      { id: run.id, status: run.status, goal: run.goal, scope: run.external_metadata.dig("layered_verification_audit", "scope"), target_revision: revision, budget_cents: }
    end

    private

    def project_for(id)
      @projects_by_id ||= {}
      @projects_by_id[id] ||= policy_scope(Project).find(id)
    end
  end
end
