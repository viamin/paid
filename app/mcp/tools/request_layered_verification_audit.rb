# frozen_string_literal: true

module Tools
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.description = "Show and, after confirmation, queue a bounded issue-less verification audit for project obligations."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| AuditAccessAllowed.call(user:, project:) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      session&.project.present? && available_to?(user:)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          obligation_ids: { type: "array", items: { type: "integer" } },
          budget: { type: "integer" },
          confirmed: { type: "boolean" }
        },
        required: %w[project_id obligation_ids budget confirmed]
      }
    end

    def perform(project_id:, obligation_ids:, budget:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an audit" unless confirmed

      run = LayeredVerification::Audits::Request.call(project: project_for(project_id), user: current_user, obligation_ids:, budget:)
      { id: run.id, project_id: run.project_id, goal: run.goal, status: run.status, audit: run.external_metadata.fetch("layered_verification_audit") }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end

  class AuditAccessAllowed
    def self.call(...) = new(...).call

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    def call
      FeatureFlags.enabled?(:layered_verification_add_on, project: project) && ProjectPolicy.new(user, project).manage_issues?
    end

    private

    attr_reader :project, :user
  end
end
