# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Prepare and dispatch a bounded, issue-less verification audit for a project. It records evidence and findings only; it never starts repair."
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && available_for_project?(user:, project:)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          target_revision: { type: "string" }, budget: { type: "object" }, selections: { type: "object" },
          confirmed: { type: "boolean" }
        }, required: %w[project_id obligation_ids target_revision budget confirmed]
      }
    end

    # A preview is safe to return before a human approves it. The registry
    # injects +confirmed+ only after chat confirmation; MCP and the project UI
    # must explicitly provide the same human-approved value.
    def perform(project_id:, obligation_ids:, target_revision:, budget:, selections: {}, confirmed: false)
      project = project_for(project_id)
      obligations = project.layered_verification_obligations.where(id: obligation_ids).order(:id)
      raise ArgumentError, "select at least one obligation" if obligations.empty?

      payload = preview(project:, obligations:, target_revision:, budget:, selections:)
      return payload unless confirmed

      run = LayeredVerification::Audits::Request.call(
        project:, user: current_user,
        obligation_ids: payload.fetch("obligation_ids"), target_revision: payload.fetch("target_revision"),
        budget: payload.fetch("budget"), selections: payload.fetch("plan")
      )
      { id: run.id, status: run.status, goal: run.goal }
    end

    private

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def project_for(id) = policy_scope(Project).find(id)

    def preview(project:, obligations:, target_revision:, budget:, selections:)
      target_revision = LayeredVerification::Audits::Request.resolve_target_revision!(project:, target_revision:)
      { "project_id" => project.id, "obligation_ids" => obligations.ids, "target_revision" => target_revision,
        "budget" => budget, "plan" => LayeredVerification::Plans::Build.call(obligations:, selections:) }
    end
  end
end
