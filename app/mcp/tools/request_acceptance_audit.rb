# frozen_string_literal: true

module Tools
  class RequestAcceptanceAudit < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_acceptance_audit"
    def self.write_operation? = true
    def self.description
      "Queue one bounded, report-only acceptance audit for a stalled partial closeout. " \
        "It refreshes the persisted criterion assessment and never authorizes implementation. Requires confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, issue_id: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id issue_id confirmed] }
    end

    def perform(project_id:, issue_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request an acceptance audit" unless confirmed

      project = project_for(project_id)
      result = Issues::RequestAcceptanceAudit.call(issue: project.issues.find(issue_id), actor: current_user)
      raise ArgumentError, result.message unless result.success?

      { request_id: result.request.id, agent_run_id: result.agent_run.id, status: result.agent_run.status }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
