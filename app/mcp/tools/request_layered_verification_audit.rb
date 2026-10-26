# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Prepare a bounded, issue-less layered-verification audit. It reports only and requires approval of the resolved scope before dispatch."
    end

    def self.available_to?(user:)
      enabled_projects_for(user).any?
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "Project to audit" },
          obligation_ids: { type: "array", items: { type: "integer" }, description: "Bounded obligations to audit" },
          target_revision: { type: "string", description: "Pinned repository revision" },
          budget_tokens: { type: "integer", description: "Maximum token budget" },
          selected_checks: { type: "array", items: { type: "object" }, description: "Agent-proposed checks with fit and limitations" },
          omissions: { type: "array", items: { type: "object" }, description: "Explained checks not applicable to this audit" }
        },
        required: %w[project_id obligation_ids target_revision budget_tokens selected_checks]
      }
    end

    def perform(project_id:, obligation_ids:, target_revision:, budget_tokens:, selected_checks:, omissions: [])
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      plan = LayeredVerification::Plans::Build.call(selected_checks:, omissions:)
      preview(project:, obligations: obligations_for(project, obligation_ids), target_revision:, budget_tokens:, plan:)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "decision must be approve or deny" unless decision.in?([ :approve, :deny ])
      return pending_result if decision == :deny

      TenantContext.with(account) do
        project = project_for(pending_result.fetch("project_id"))
        LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
        run = LayeredVerification::Audits::Request.call(
          project:,
          user: current_user,
          obligations: obligations_for(project, pending_result.fetch("obligation_ids")),
          target_revision: pending_result.fetch("target_revision"),
          budget_tokens: pending_result.fetch("budget_tokens"),
          plan: pending_result.fetch("plan")
        )
        { "agent_run_id" => run.id, "status" => run.status }
      end
    end

    private

    def self.enabled_projects_for(user)
      Pundit.policy_scope!(user, Project).select do |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
          policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    end

    def project_for(id) = policy_scope(Project).find(id)

    def obligations_for(project, ids)
      project.layered_verification_obligations.where(id: Array(ids)).order(:id).tap do |obligations|
        raise ArgumentError, "every requested obligation must belong to the project" unless obligations.size == Array(ids).size
      end
    end

    def preview(project:, obligations:, target_revision:, budget_tokens:, plan:)
      {
        "project_id" => project.id,
        "obligation_ids" => obligations.map(&:id),
        "target_revision" => target_revision,
        "budget_tokens" => budget_tokens.to_i,
        "plan" => plan
      }
    end
  end
end
