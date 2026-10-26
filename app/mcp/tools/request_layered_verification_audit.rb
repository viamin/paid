# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Show and, after confirmation, queue a bounded layered-verification audit. It only records evidence and findings; it never starts repair."
    def self.available_to?(user:) = run_agent_available_to?(user:)
    def self.available_for_chat?(user:, session:) = user.present? && session.project.present? && available_to?(user:)

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, scope: { type: "array" }, sources: { type: "array" }, target_revision: { type: "string" }, budget: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id scope sources target_revision budget confirmed] }
    end

    # @spec LAYERED-VERIFY-014
    def perform(project_id:, scope:, sources:, target_revision:, budget:, confirmed: false)
      raise ArgumentError, "Confirmation required after reviewing resolved audit scope" unless confirmed
      run = LayeredVerification::Audits::Request.call(project: project_for(project_id), user: current_user,
        scope: Array(scope), sources: Array(sources), target_revision:, budget:)
      ProcessRunQueueJob.perform_later
      { id: run.id, status: run.status, goal: run.goal, scope: scope, sources: sources, target_revision: target_revision, budget: budget }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
