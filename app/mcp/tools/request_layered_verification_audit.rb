# frozen_string_literal: true

module Tools
  # Shared UI/chat/MCP audit admission. The first call resolves and displays a
  # bounded plan; only its human confirmation creates the issue-less run.
  # @spec LAYERED-VERIFY-010
  # @spec LAYERED-VERIFY-013
  # @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Resolve and request a bounded, issue-less verification audit for the current project."

    def self.available_to?(user:)
      visible_projects(user).any?
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          obligation_ids: { type: "array", items: { type: "integer" } },
          budget_tokens: { type: "integer", minimum: 1 }
        },
        required: %w[project_id budget_tokens]
      }
    end

    def perform(project_id:, budget_tokens:, obligation_ids: [])
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project: project)
      obligations = scoped_obligations(project, obligation_ids)

      summary(project, obligations, budget_tokens)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "audit request was not confirmed" unless decision == :approve

      project = project_for(pending_result.fetch("project_id"))
      LayeredVerification::AuditAccess.authorize!(user: current_user, project: project)
      obligations = scoped_obligations(project, pending_result.fetch("obligation_ids"))
      raise ArgumentError, "audit scope changed; review it again before dispatch" unless same_scope?(obligations, pending_result)

      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      run = AgentRun.create!(
        project:, initiating_user: current_user, runner_id:, agent_type:, goal: "layered_verification_audit",
        status: "queued", trigger_type: "manual", token_limit_status: "within_limit",
        external_metadata: pending_result.slice("obligation_ids", "source_references", "target_revision", "budget_tokens")
      )
      ProcessRunQueueJob.perform_later
      pending_result.merge("agent_run_id" => run.id, "status" => run.status)
    end

    private

    def self.visible_projects(user)
      Pundit.policy_scope!(user, Project).select { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      []
    end

    def project_for(id) = policy_scope(Project).find(id)

    def scoped_obligations(project, ids)
      scope = project.layered_verification_obligations
      ids.present? ? scope.where(id: ids).to_a : scope.where.not(approval_state: "unresolved").to_a
    end

    def summary(project, obligations, budget_tokens)
      {
        "project_id" => project.id,
        "obligation_ids" => obligations.map(&:id),
        "source_references" => obligations.map(&:external_identity),
        "target_revision" => obligations.map(&:external_revision).compact.uniq.sort,
        "budget_tokens" => Integer(budget_tokens),
        "dispatch" => "awaiting_confirmation"
      }
    end

    def same_scope?(obligations, pending_result)
      pending_result.fetch("obligation_ids").map(&:to_i).sort == obligations.map(&:id).sort &&
        pending_result.fetch("target_revision") == obligations.map(&:external_revision).compact.uniq.sort
    end
  end
end
