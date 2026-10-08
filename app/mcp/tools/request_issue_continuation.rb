# frozen_string_literal: true

module Tools
  class RequestIssueContinuation < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_issue_continuation"
    def self.write_operation? = true
    def self.description
      "Request one evidence-scoped continuation for a stalled partial closeout. " \
        "Authorizes exactly one run; dependencies, trust, feature gates, budgets, pauses, and review holds still apply. " \
        "The reason must describe the remaining work and the expected evidence (for example a fresh acceptance audit, " \
        "an implementation gap, scanner verification, or human-only evaluation). Requires confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, issue_id: { type: "integer" }, reason: { type: "string" }, confirmed: { type: "boolean" } }, required: %w[project_id issue_id reason confirmed] }
    end

    def perform(project_id:, issue_id:, reason:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request continuation" unless confirmed

      project = project_for(project_id)
      result = Issues::RequestContinuation.call(issue: project.issues.find(issue_id), actor: current_user, reason:)
      raise ArgumentError, result.message unless result.success?

      { request_id: result.request.id, agent_run_id: result.agent_run.id, status: result.agent_run.status }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
