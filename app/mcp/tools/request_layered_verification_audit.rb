# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.confirmation_mode = :post_dispatch
    def self.description = "Request a bounded, issue-less verification audit for the current project's selected obligations."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && available_for_project?(user:, project:)
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          budget: { type: "object" }, checks: { type: "array", items: { type: "object" } },
          exclusions: { type: "array", items: { type: "object" } }, target_revision: { type: "string" }
        }, required: %w[project_id obligation_ids budget]
      }
    end

    def perform(project_id:, obligation_ids:, budget:, checks: [], exclusions: [], target_revision: nil)
      # @spec LAYERED-VERIFY-014
      run = LayeredVerification::Audits::Request.call(
        project: project_for(project_id), user:, obligation_ids:, budget:, checks:, exclusions:, target_revision:
      )
      { id: run.id, project_id: run.project_id, goal: run.goal, status: run.status, audit: run.external_metadata.fetch("layered_verification_audit") }
    end

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    rescue ActiveRecord::RecordNotFound
      raise UnauthorizedError, "Project not found or not accessible"
    end
  end
end
