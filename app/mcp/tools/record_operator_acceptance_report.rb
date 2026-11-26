# frozen_string_literal: true

module Tools
  class RecordOperatorAcceptanceReport < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "record_operator_acceptance_report"
    def self.write_operation? = true
    def self.description
      "Record one trusted PR comment as an evidence-only operator acceptance report at the current revision. " \
        "It never queues coding work or changes repair allowances. Requires explicit confirmation."
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, pull_request_id: { type: "integer" }, comment_id: { type: "integer" },
        environment: { type: "string" }, results: { type: "string" }, unrun_capabilities: { type: "array", items: { type: "string" } },
        confirmed: { type: "boolean" }
      }, required: %w[project_id pull_request_id comment_id environment results confirmed] }
    end

    def perform(project_id:, pull_request_id:, comment_id:, environment:, results:, unrun_capabilities: [], confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to record an operator acceptance report" unless confirmed

      project = project_for(project_id)
      result = PullRequests::RecordOperatorAcceptanceReport.call(
        pull_request: project.issues.pull_requests_only.find(pull_request_id), actor: current_user,
        comment_id:, environment:, results:, unrun_capabilities:
      )
      { event_id: result.event.id, created: result.created?, revision: result.event.metadata.fetch("revision") }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
