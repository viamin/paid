# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.description = "Preview or queue a bounded, issue-less layered-verification audit. It records evidence and findings only; it never starts a repair."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      return false unless session&.project

      FeatureFlags.enabled?(:layered_verification_add_on, project: session.project) && policy_allows?(user:, record: session.project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object", properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          source_references: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
          budget: { type: "integer" }, confirmed: { type: "boolean" }
        }, required: %w[project_id obligation_ids target_revision budget confirmed]
      }
    end

    def perform(project_id:, obligation_ids:, target_revision:, budget:, source_references: [], confirmed: false)
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      preview = preview_for(project:, obligation_ids:, target_revision:, budget:)
      return preview.merge("dispatch_required" => true) unless confirmed

      result = LayeredVerification::Audits::Request.call(user: current_user, project:, obligation_ids:, source_references:, target_revision:, budget:)
      preview.merge("run_id" => result.run.id, "status" => result.run.status, "dispatch_required" => false)
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    def preview_for(project:, obligation_ids:, target_revision:, budget:)
      obligations = project.layered_verification_obligations.where(id: obligation_ids).order(:id)
      raise ArgumentError, "an audit needs at least one obligation" if obligations.empty?

      { "resolved_scope" => obligations.pluck(:external_identity), "target_revision" => target_revision, "budget" => budget.to_i, "initiating_user_id" => current_user.id }
    end
  end
end
