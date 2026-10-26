# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Resolve a bounded project audit scope and budget, then request human confirmation before dispatching an issue-less audit run."

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
      { type: "object", properties: { project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } }, budget: { type: "integer" } }, required: %w[project_id obligation_ids budget] }
    end

    def perform(project_id:, obligation_ids:, budget:)
      project = project_for(project_id)
      obligations = project.layered_verification_obligations.where(id: obligation_ids).to_a
      raise ArgumentError, "one or more obligations are outside this project" unless obligations.size == Array(obligation_ids).size

      preview(project:, obligations:, budget:)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "audit request was not confirmed" unless decision == :approve

      project = project_for(pending_result.fetch("project_id"))
      obligations = project.layered_verification_obligations.where(id: pending_result.fetch("obligation_ids")).to_a
      run = LayeredVerification::Audits::Request.call(project:, user: current_user, obligations:, budget: pending_result.fetch("budget"))
      ProcessRunQueueJob.perform_later
      { id: run.id, status: run.status, goal: run.goal }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    def preview(project:, obligations:, budget:)
      raise ArgumentError, "budget must be positive" unless budget.to_i.positive?

      { "project_id" => project.id, "obligation_ids" => obligations.map(&:id), "budget" => budget.to_i,
        "scope" => obligations.map { |obligation| { "identity" => obligation.external_identity, "revision" => obligation.external_revision, "description" => obligation.scope_description } },
        "plan" => LayeredVerification::Plans::Build.call(obligations:) }
    end
  end
end
