# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Preview a bounded, issue-less layered-verification audit, then queue it after human confirmation."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| LayeredVerification::AuditAccess.authorize!(user:, project:) }
    rescue LayeredVerification::AuditAccess::FeatureDisabledError, LayeredVerification::AuditAccess::UnauthorizedError, Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && LayeredVerification::AuditAccess.authorize!(user:, project:)
    rescue LayeredVerification::AuditAccess::FeatureDisabledError, LayeredVerification::AuditAccess::UnauthorizedError
      false
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } } }, required: [ "project_id" ] }
    end

    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    def perform(project_id:, obligation_ids: nil)
      request = LayeredVerification::Audits::Request.new(project: project_for(project_id), user: current_user, obligation_ids:)
      scope = request.send(:resolved_scope)
      raise ArgumentError, "Select at least one layered-verification obligation" if scope.empty?

      { project_id:, obligation_ids: scope.map(&:id), scope: scope.map { |o| { id: o.id, description: o.scope_description, revision: o.external_revision } },
        budget_tokens: project_for(project_id).project_level_max_tokens_per_run, status: "awaiting_confirmation" }
    end

    def resolve_confirmation(decision:, pending_result:)
      return pending_result if decision == :deny
      raise ArgumentError, "decision must be approve or deny" unless decision == :approve

      result = LayeredVerification::Audits::Request.call(project: project_for(pending_result.fetch("project_id")), user: current_user,
        obligation_ids: pending_result.fetch("obligation_ids"))
      { id: result.agent_run.id, status: result.agent_run.status, scope: result.scope.map(&:id), budget_tokens: result.budget }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
