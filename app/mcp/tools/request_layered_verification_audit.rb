# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Queue a bounded, issue-less layered-verification audit after confirming its resolved scope, sources, revision, and budget. It never authorizes repair."
    end

    def self.available_to?(user:)
      enabled_projects_for(user:).any?
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && enabled_project_for?(user:, project:)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          target_revision: { type: "string" },
          obligation_ids: { type: "array", items: { type: "integer" } },
          confirmed: { type: "boolean" }
        },
        required: %w[project_id confirmed]
      }
    end

    def perform(project_id:, confirmed: false, target_revision: nil, obligation_ids: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to request a layered-verification audit" unless confirmed

      run = LayeredVerification::Audits::Request.call(
        project: project_for(project_id), user:, target_revision:, obligation_ids:
      )
      { "id" => run.id, "project_id" => run.project_id, "goal" => run.goal, "status" => run.status,
        "audit" => run.external_metadata.fetch("layered_verification_audit") }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    class << self
      private

      def enabled_projects_for(user:)
        return Project.none if user.blank?

        Pundit.policy_scope!(user, Project).select { |project| enabled_project_for?(user:, project:) }
      rescue Pundit::NotAuthorizedError
        Project.none
      end

      def enabled_project_for?(user:, project:)
        FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
          policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    end
  end
end
