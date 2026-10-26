# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy
    # @spec LAYERED-VERIFY-014
    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Request a bounded, issue-less verification audit for a project."
    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    end
    def self.available_for_chat?(user:, session:)
      session&.project && policy_allows?(user:, record: session.project, query: :manage_issues?, policy_class: ProjectPolicy)
    end
    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } }, target_revision: { type: "string" }, budget: { type: "integer" }, sources: { type: "array", items: { type: "string" } }, requested_checks: { type: "array", items: { type: "string" } } }, required: %w[project_id obligation_ids target_revision budget] }
    end
    def perform(project_id:, obligation_ids:, target_revision:, budget:, sources: [], requested_checks: [])
      run = LayeredVerification::Audits::Request.call(user:, project: project_for(project_id), obligation_ids:, target_revision:, budget:, sources:, requested_checks:)
      metadata = run.external_metadata.fetch("layered_verification")
      { id: run.id, project_id: run.project_id, status: run.status, scope: metadata.slice("obligation_ids", "sources", "target_revision", "budget"), plan: metadata.fetch("plan") }
    end
    private
    def project_for(project_id) = policy_scope(Project).find(project_id)
  end
end
