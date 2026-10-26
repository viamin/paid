# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Show and then queue a bounded, issue-less layered-verification audit. It records evidence and findings only; it never starts repair."
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? do |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
          policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      available_to?(user:) && session&.project_id.present?
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, scope: { type: "string" }, sources: { type: "array", items: { type: "string" } },
          target_revision: { type: "string" }, budget: { type: "integer", minimum: 1 }, confirmed: { type: "boolean" }
        },
        required: %w[project_id scope sources target_revision budget confirmed]
      }
    end

    # @spec LAYERED-VERIFY-010
    # @spec LAYERED-VERIFY-013
    def perform(project_id:, scope:, sources:, target_revision:, budget:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request a layered-verification audit" unless confirmed

      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      run = AgentRun.create!(
        project:, initiating_user: current_user, runner_id:, agent_type:, goal: "layered_verification_audit",
        review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
        external_metadata: { "scope" => scope, "sources" => sources, "target_revision" => target_revision, "budget" => budget }
      )
      ProcessRunQueueJob.perform_later

      { id: run.id, project_id: run.project_id, status: run.status, goal: run.goal, resolved_scope: scope, sources:, target_revision:, budget: }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
