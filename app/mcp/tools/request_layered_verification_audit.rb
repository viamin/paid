# frozen_string_literal: true

module Tools
  # @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Show the resolved verification scope, checks, revision, and budget, then queue an issue-less audit. It never starts repair work."
    def self.available_to?(user:) = managed_project_available?(user:)
    def self.available_for_chat?(user:, session:)
      project = session&.project_id && Pundit.policy_scope!(user, Project).find_by(id: session.project_id)
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } }, budget_tokens: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id obligation_ids budget_tokens confirmed] }
    end

    def perform(project_id:, obligation_ids:, budget_tokens:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an audit" unless confirmed

      run = LayeredVerification::Audits::Request.call(project: project_for(project_id), user: current_user, obligation_ids:, budget_tokens:)
      { id: run.id, status: run.status, goal: run.goal, scope: run.external_metadata.fetch("obligation_ids"), budget_tokens: }
    end

    def self.managed_project_available?(user:)
      Pundit.policy_scope!(user, Project).any? do |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
