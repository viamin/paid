# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(_args) { project_for_session! }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.mcp_available? = true

    def self.description
      "Request an issue-less, bounded layered-verification audit for the current project."
    end

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          obligation_ids: { type: "array", items: { type: "integer" } },
          sources: { type: "array", items: { type: "string" } },
          target_revision: { type: "string" },
          budget_tokens: { type: "integer" }
        },
        required: %w[obligation_ids sources target_revision budget_tokens]
      }
    end

    def perform(obligation_ids:, sources:, target_revision:, budget_tokens:)
      project = project_for_session!
      LayeredVerification::AuditAccess.authorize!(user:, project:)
      obligations = project.layered_verification_obligations.where(id: obligation_ids).order(:id)
      raise ArgumentError, "Select at least one project obligation." if obligations.empty?
      raise ArgumentError, "Every selected obligation must be resolved." unless obligations.count == Array(obligation_ids).uniq.count

      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      raise ArgumentError, "No runnable runner could be resolved for this project." if agent_type.blank?

      run = AgentRun.create!(
        project:,
        initiating_user: user,
        runner_id:,
        agent_type:,
        goal: "layered_verification_audit",
        review_depth_snapshot: project.effective_review_depth,
        status: "queued",
        trigger_type: "manual",
        external_metadata: metadata(obligations:, sources:, target_revision:, budget_tokens:)
      )
      ProcessRunQueueJob.perform_later
      serialized(run)
    end

    private

    def project_for_session!
      session.project || raise(ArgumentError, "request_layered_verification_audit requires a project-scoped chat session")
    end

    def metadata(obligations:, sources:, target_revision:, budget_tokens:)
      {
        "layered_verification_audit" => {
          "obligation_ids" => obligations.ids,
          "scope" => obligations.map(&:scope_description),
          "sources" => Array(sources),
          "target_revision" => target_revision,
          "budget_tokens" => budget_tokens
        }
      }
    end

    def serialized(run)
      audit = run.external_metadata.fetch("layered_verification_audit")
      { id: run.id, status: run.status, goal: run.goal, project_id: run.project_id, **audit }
    end
  end
end
