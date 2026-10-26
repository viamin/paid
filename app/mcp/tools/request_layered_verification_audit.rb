# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Show and dispatch one bounded, issue-less verification audit for a project. It never authorizes repair."

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
      { type: "object", properties: { project_id: { type: "integer" }, scope: { type: "array", items: { type: "string" } },
        sources: { type: "array", items: { type: "string" } }, target_revision: { type: "string" }, budget: { type: "integer" } },
        required: %w[project_id scope sources target_revision budget] }
    end

    def perform(project_id:, scope:, sources:, target_revision:, budget:)
      run = LayeredVerification::Audits::Request.call(project: project_for(project_id), user: current_user,
        scope:, sources:, target_revision:, budget:)
      metadata = run.external_metadata.fetch("layered_verification_audit")
      metadata.merge("agent_run_id" => run.id, "status" => run.status)
    rescue LayeredVerification::AuditAccess::FeatureDisabledError, LayeredVerification::AuditAccess::UnauthorizedError,
           LayeredVerification::Audits::Request::BudgetExceededError, LayeredVerification::Audits::Request::NoRunnableRunnerError => error
      raise ArgumentError, error.message
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
