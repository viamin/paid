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
      "Preview and request a bounded, issue-less layered-verification audit. It records evidence and findings only; it never starts repair."
    end

    def self.available_to?(user:)
      available_projects(user:).any?
    end

    def self.available_for_chat?(user:, session:)
      session&.project && policy_allows?(user:, record: session.project, query: :manage_issues?, policy_class: ProjectPolicy) &&
        FeatureFlags.enabled?(:layered_verification_add_on, project: session.project)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, scope: { type: "string" }, sources: { type: "array", items: { type: "string" } },
          target_revision: { type: "string" }, budget: { type: "integer" }, checks: { type: "array", items: { type: "object" } },
          omissions: { type: "array", items: { type: "object" } }, confirmed: { type: "boolean" }
        }, required: %w[project_id scope sources target_revision budget confirmed]
      }
    end

    def perform(project_id:, scope:, sources:, target_revision:, budget:, checks: [], omissions: [], confirmed: false)
      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      plan = LayeredVerification::Plans::Build.call(scope:, sources:, target_revision:, budget:, checks:, omissions:)
      return preview(plan) unless confirmed

      run = create_run(project:, plan:)
      ProcessRunQueueJob.perform_later
      preview(plan).merge(id: run.id, status: run.status, dispatched: true)
    rescue LayeredVerification::AuditAccess::FeatureDisabledError, LayeredVerification::AuditAccess::UnauthorizedError => error
      raise UnauthorizedError, error.message
    end

    private

    def self.available_projects(user)
      return Project.none if user.blank?

      Pundit.policy_scope!(user, Project).select do |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      Project.none
    end

    def project_for(id)
      policy_scope(Project).find(id)
    end

    def preview(plan)
      {
        resolved_scope: plan.scope, sources: plan.sources, target_revision: plan.target_revision, budget: plan.budget,
        selected_checks: plan.selected_checks, omissions: plan.omissions, dispatched: false
      }
    end

    def create_run(project:, plan:)
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      AgentRun.create!(
        project:, initiating_user: current_user, runner_id:, agent_type:, goal: "layered_verification_audit", status: "queued", trigger_type: "manual",
        review_depth_snapshot: project.effective_review_depth,
        external_metadata: {
          "resolved_scope" => plan.scope, "sources" => plan.sources, "target_revision" => plan.target_revision,
          "budget" => plan.budget, "verification_plan" => { "selected_checks" => plan.selected_checks, "omissions" => plan.omissions },
          "waiting_reasons" => []
        }
      )
    end
  end
end
