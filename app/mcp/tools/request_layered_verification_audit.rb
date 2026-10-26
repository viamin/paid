# frozen_string_literal: true

module Tools
  # @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Request a bounded, issue-less, audit-only layered verification run for a project. Requires confirmation."
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? do |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      return available_to?(user:) if session.nil?

      project = session&.project
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
        sources: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
        budget: { type: "object" }, confirmed: { type: "boolean" }
      }, required: %w[project_id obligation_ids sources target_revision confirmed] }
    end

    def perform(project_id:, obligation_ids:, sources:, target_revision:, budget: {}, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an audit" unless confirmed

      run = LayeredVerification::Audits::Request.call(user: current_user, project: project_for(project_id), obligation_ids:, sources:, target_revision:, budget:)
      { id: run.id, project_id: run.project_id, goal: run.goal, status: run.status, audit: run.external_metadata.fetch("layered_verification_audit") }
    end

    private

    def project_for(project_id)
      policy_scope(Project).find(project_id)
    end
  end
end
