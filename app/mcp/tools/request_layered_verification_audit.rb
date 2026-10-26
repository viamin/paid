# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.description = "Show and dispatch a bounded, report-only layered verification audit. It never starts repair."
    def self.available_to?(user:) = available_projects?(user:)
    def self.available_for_chat?(user:, session:)
      session&.project && FeatureFlags.enabled?(:layered_verification_add_on, project: session.project) &&
        ProjectPolicy.new(user, session.project).manage_issues?
    end
    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, scope: { type: "array", items: { type: "string" } }, source_references: { type: "array", items: { type: "string" } }, target_revision: { type: "string" }, budget: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id scope source_references target_revision budget confirmed] }
    end

    def perform(project_id:, scope:, source_references:, target_revision:, budget:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to dispatch the resolved audit scope" unless confirmed

      result = LayeredVerification::Audits::Request.call(project: project_for(project_id), actor: current_user,
        scope:, source_references:, target_revision:, budget:)
      { agent_run_id: result.agent_run.id, status: result.agent_run.status, scope: result.scope, budget: result.budget, trigger: result.trigger }
    end

    def self.available_projects?(user:)
      return false unless user

      Pundit.policy_scope!(user, Project).any? { |project| FeatureFlags.enabled?(:layered_verification_add_on, project:) && ProjectPolicy.new(user, project).manage_issues? }
    rescue Pundit::NotAuthorizedError
      false
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
