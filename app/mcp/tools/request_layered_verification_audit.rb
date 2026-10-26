# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Resolve and preview a bounded report-only verification audit, then dispatch it after human confirmation. It never starts a repair."
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && available_for_project?(user:, project:)
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
        budget: { type: "integer" }, target_revision: { type: "string" }, formal_model: { type: "object" }
      }, required: [ "project_id" ] }
    end

    def perform(project_id:, obligation_ids: nil, budget: nil, target_revision: nil, formal_model: nil)
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      LayeredVerification::Audits::Request.preview(project:, user: current_user, obligation_ids:, budget:, target_revision:, formal_model:).to_h
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "decision must be approve or deny" unless decision.in?([ :approve, :deny ])
      return { status: "cancelled" } if decision == :deny

      TenantContext.with(account) do
        preview = pending_result.deep_stringify_keys
        project = policy_scope(Project).find(preview.fetch("project_id"))
        run = LayeredVerification::Audits::Request.dispatch(
          project:, user: current_user, obligation_ids: preview.fetch("scope").map { |item| item.fetch("id") },
          budget: preview.fetch("budget"), target_revision: preview["target_revision"]
        )
        { id: run.id, status: run.status, goal: run.goal }
      end
    end

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project,
        query: :manage_issues?, policy_class: ProjectPolicy)
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
