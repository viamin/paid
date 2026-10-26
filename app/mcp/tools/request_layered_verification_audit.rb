# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(_args) { project_for_session! }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.mcp_available? = true

    def self.description
      "Preview a bounded, report-only layered-verification audit for this project. Confirmation queues the audit; it never starts a repair."
    end

    def self.available_to?(user:) = user.present?

    def self.available_for_chat?(user:, session:)
      user.present? && session&.project.present? && policy_allows?(user:, record: session.project,
        query: :manage_issues?, policy_class: ProjectPolicy) && FeatureFlags.enabled?(:layered_verification_add_on, project: session.project)
    end

    def self.input_schema
      { type: "object", properties: {
        obligation_ids: { type: "array", items: { type: "integer" } },
        source_references: { type: "array", items: { type: "string" } },
        target_revision: { type: "string" }, budget: { type: "integer" }
      }, required: %w[obligation_ids source_references target_revision budget] }
    end

    def perform(obligation_ids:, source_references:, target_revision:, budget:)
      request = request_attributes(obligation_ids:, source_references:, target_revision:, budget:)
      preview(request)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "audit request was not approved" unless decision == :approve

      request = pending_result.fetch("request").symbolize_keys
      result = LayeredVerification::Audits::Request.call(project: project_for_session!, actor: current_user, **request)
      { id: result.agent_run.id, status: result.agent_run.status, goal: result.agent_run.goal,
        scope: result.scope, sources: result.sources, target_revision: result.target_revision, budget: result.budget }
    end

    private

    def project_for_session!
      session.project || raise(ArgumentError, "request_layered_verification_audit requires a project-scoped chat")
    end

    def request_attributes(obligation_ids:, source_references:, target_revision:, budget:)
      { obligation_ids: Array(obligation_ids).map(&:to_i), source_references: Array(source_references).map(&:to_s),
        target_revision: target_revision.to_s, budget: budget.to_i }
    end

    def preview(request)
      obligations = project_for_session!.layered_verification_obligations.where(id: request[:obligation_ids])
      raise ArgumentError, "every requested obligation must belong to the project" unless obligations.size == request[:obligation_ids].size

      { status: "awaiting_confirmation", request:, scope: obligations.order(:id).pluck(:scope_description),
        initiating_user_id: current_user.id, repair_authorized: false }
    end
  end
end
