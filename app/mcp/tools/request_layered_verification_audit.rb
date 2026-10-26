# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    # @spec LAYERED-VERIFY-014
    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.description = "Queue a bounded, issue-less layered-verification audit. It reports evidence and never authorizes repair."
    def self.available_to?(user:) = audit_available_to?(user:)
    def self.available_for_chat?(user:, session:) = audit_available_to?(user:)

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, scope: { type: "string" }, target_revision: { type: "string" },
        budget: { type: "integer", minimum: 1 }, confirmed: { type: "boolean" }
      }, required: %w[project_id scope target_revision budget confirmed] }
    end

    # @spec LAYERED-VERIFY-010
    # @spec LAYERED-VERIFY-013
    def perform(project_id:, scope:, target_revision:, budget:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an audit" unless confirmed

      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      run = create_run(project:, scope:, target_revision:, budget:)
      ProcessRunQueueJob.perform_later
      { id: run.id, status: run.status, scope:, target_revision:, budget: }
    end

    def self.audit_available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    private

    def create_run(project:, scope:, target_revision:, budget:)
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      AgentRun.create!(project:, initiating_user: current_user, runner_id:, agent_type:, goal: "layered_verification_audit",
        review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
        external_metadata: { "scope" => scope, "target_revision" => target_revision, "budget" => budget })
    end

    def project_for(id) = policy_scope(Project).find(id)
  end
end
