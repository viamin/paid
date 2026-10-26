# frozen_string_literal: true

module Tools
  # Shared project-chat/MCP dispatch boundary for issue-less audit requests.
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Request a bounded, issue-less verification audit. It records findings and evidence only; it never repairs the project."
    end

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
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, scope: { type: "string" },
          source_references: { type: "array", items: { type: "string" } },
          target_revision: { type: "string" }, budget: { type: "integer" },
          selected_checks: { type: "array", items: { type: "string", enum: LayeredVerificationCheckResult::PRODUCERS } },
          omissions: { type: "object" }
        },
        required: %w[project_id scope source_references target_revision budget]
      }
    end

    def perform(project_id:, scope:, source_references:, target_revision:, budget:, selected_checks: [], omissions: {})
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user:, project:)
      plan = LayeredVerification::Plans::Build.call(scope:, selected_checks:, omissions:, budget:)
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      run = AgentRun.create!(
        project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
        status: "queued", trigger_type: "manual", review_depth_snapshot: project.effective_review_depth,
        external_metadata: { "scope" => scope, "source_references" => source_references, "target_revision" => target_revision, "budget" => budget, "plan" => plan }
      )
      ProcessRunQueueJob.perform_later
      { id: run.id, project_id: run.project_id, status: run.status, scope:, target_revision:, budget:, plan: }
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end
  end
end
