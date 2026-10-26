# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Prepare a bounded, report-only layered-verification audit. Confirmation dispatches it; it never authorizes repair."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } }, target_revision: { type: "string" }, budget: { type: "integer" } }, required: %w[project_id obligation_ids target_revision budget] }
    end

    def perform(project_id:, obligation_ids:, target_revision:, budget:)
      project = project_for(project_id)
      obligations = project.layered_verification_obligations.where(id: obligation_ids).select(:id, :external_identity, :scope_description).map(&:attributes)
      raise ArgumentError, "Select at least one obligation" if obligations.empty?

      { project_id: project.id, obligation_ids: obligations.pluck("id"), obligations:, target_revision:, budget: budget.to_i, action: "confirm to dispatch report-only audit" }
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "Audit dispatch was not confirmed" unless decision == :approve

      result = pending_result.stringify_keys
      run = LayeredVerification::Audits::Request.call(project: project_for(result.fetch("project_id")), actor: current_user,
        obligation_ids: result.fetch("obligation_ids"), target_revision: result.fetch("target_revision"), budget: result.fetch("budget"))
      { agent_run_id: run.id, status: run.status, progress_url: "/projects/#{run.project_id}/agent_runs/#{run.id}" }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
