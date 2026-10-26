# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch

    def self.description
      "Queue a bounded, issue-less verification audit after showing its scope, sources, revision, and budget. The audit only investigates; it never starts a repair."
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
      project = session&.project
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          obligation_ids: { type: "array", items: { type: "string" }, description: "Bounded obligation identities" },
          source_references: { type: "array", items: { type: "string" }, description: "Sources to assess" },
          target_revision: { type: "string", description: "Pinned repository revision" },
          budget_tokens: { type: "integer", description: "Maximum token budget" }
        },
        required: %w[project_id obligation_ids source_references target_revision budget_tokens]
      }
    end

    def perform(project_id:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
      # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
      run = LayeredVerification::Audits::Request.call(
        user:,
        project: project_for(project_id),
        obligation_ids:,
        source_references:,
        target_revision:,
        budget_tokens:
      )

      { id: run.id, project_id: run.project_id, goal: run.goal, status: run.status, issue_id: run.issue_id,
        audit_request: run.external_metadata.fetch("layered_verification_audit") }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
