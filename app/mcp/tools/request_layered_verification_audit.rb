# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014 @spec LAYERED-VERIFY-021
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Show and dispatch an issue-less, bounded audit run. It records evidence and findings but never starts a repair."
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      session&.project.present? && available_for_project?(user:, project: session.project)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          target_revision: { type: "string" }, budget_tokens: { type: "integer" }, selected_checks: { type: "array", items: { type: "object" } },
          exclusions: { type: "array", items: { type: "object" } }, confirmed: { type: "boolean" }
        }, required: %w[project_id obligation_ids target_revision budget_tokens selected_checks confirmed]
      }
    end

    def perform(project_id:, obligation_ids:, target_revision:, budget_tokens:, selected_checks:, exclusions: [], confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to dispatch an audit" unless confirmed

      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user:, project:)
      obligations = project.layered_verification_obligations.where(id: obligation_ids)
      raise ArgumentError, "Select at least one project obligation" if obligations.empty? || obligations.size != obligation_ids.uniq.size
      raise ArgumentError, "Budget must be positive" unless budget_tokens.to_i.positive?

      plan = LayeredVerification::Plans::Build.call(selected_checks:, exclusions:)
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      run = AgentRun.create!(project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
        review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
        external_metadata: { "layered_verification" => { "obligation_ids" => obligations.ids, "target_revision" => target_revision,
          "budget_tokens" => budget_tokens.to_i, "plan" => serialize_plan(plan), "initiating_user_id" => user.id } })
      ProcessRunQueueJob.perform_later
      { id: run.id, status: run.status, goal: run.goal, project_id: project.id, issue_id: nil }
    end

    private

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end

    def serialize_plan(plan)
      { "selected_checks" => plan.selected_checks.map(&:to_h), "exclusions" => plan.exclusions }
    end
  end
end
