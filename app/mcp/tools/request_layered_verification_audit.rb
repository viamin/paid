# frozen_string_literal: true

module Tools
  # The sole project-scoped entry point for an issue-less audit.  Keeping the
  # preview and dispatch together prevents chat and MCP from drifting apart.
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.description = "Preview and, after confirmation, queue a bounded issue-less layered-verification audit. It records evidence only and never starts repair."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? do |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project && available_to_project?(user:, project:)
    end

    def self.available_to_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" },
        obligation_ids: { type: "array", items: { type: "integer" }, description: "Bounded obligation scope; omit for all current project obligations." },
        budget_tokens: { type: "integer", minimum: 1 },
        confirmed: { type: "boolean", description: "Set true only after reviewing the resolved preview." }
      }, required: %w[project_id] }
    end

    def perform(project_id:, obligation_ids: nil, budget_tokens: nil, confirmed: false)
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      preview = preview_for(project:, obligation_ids:, budget_tokens:)
      return preview.merge(dispatchable: false) unless confirmed

      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      run = AgentRun.create!(project:, initiating_user: current_user, runner_id:, agent_type:,
        goal: "layered_verification_audit", status: "queued", trigger_type: "manual",
        review_depth_snapshot: project.effective_review_depth,
        external_metadata: preview.slice(:scope, :target_revision, :budget_tokens).merge("trigger" => "project_scoped_tool"))
      ProcessRunQueueJob.perform_later
      preview.merge(id: run.id, status: run.status, dispatchable: true)
    end

    private

    def project_for(id) = policy_scope(Project).find(id)

    def preview_for(project:, obligation_ids:, budget_tokens:)
      obligations = project.layered_verification_obligations.where(id: obligation_ids.presence || project.layered_verification_obligations.select(:id)).order(:id)
      raise ArgumentError, "At least one current project obligation is required" if obligations.empty?
      { scope: obligations.map { |o| { id: o.id, identity: o.external_identity, revision: o.external_revision, source: o.scope_description } },
        target_revision: obligations.map(&:external_revision).compact.uniq,
        budget_tokens: budget_tokens || project.account.default_max_tokens_per_run,
        limitations: [ "Audit is evidence-only; it cannot modify canonical intent, specifications, models, tests, or production code." ] }
    end
  end
end
