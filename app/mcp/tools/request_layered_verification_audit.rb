# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Preview and request a bounded, report-only layered verification audit for a project."
    def self.available_to?(user:) = available_for_project_permission?(user:)
    def self.available_for_chat?(user:, session:)
      session&.project && FeatureFlags.enabled?(:layered_verification_add_on, project: session.project) &&
        policy_allows?(user:, record: session.project, query: :manage_issues?, policy_class: ProjectPolicy)
    end
    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } }, target_revision: { type: "string" }, budget: { type: "integer" } }, required: %w[project_id obligation_ids target_revision budget] }
    end

    def perform(project_id:, obligation_ids:, target_revision:, budget:)
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      request = LayeredVerification::Audits::Request.new(user: current_user, project:, obligation_ids:, target_revision:, budget:)
      request.resolved_scope.merge("project_id" => project.id, "confirmation_required" => true)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "audit request was not approved" unless decision == :approve

      payload = pending_result.stringify_keys
      project = project_for(payload.fetch("project_id"))
      run = LayeredVerification::Audits::Request.call(user: current_user, project:, obligation_ids: payload.fetch("obligation_ids"), target_revision: payload.fetch("target_revision"), budget: payload.fetch("budget"))
      { agent_run_id: run.id, status: run.status }
    end

    def self.available_for_project_permission?(user:)
      return false if user.blank?
      Pundit.policy_scope!(user, Project).any? { |project| FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
