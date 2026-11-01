# frozen_string_literal: true

module Tools
  # @spec AUTO-PICK-QUEUE-021
  class RepairDependencyCycle < BaseTool
    include GithubIssueToolSupport

    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "repair_dependency_cycle"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Apply the bounded first-path repair for one dependency-cycle occurrence: remove the first path edge's " \
        "declaration line from the live declaring issue body after validating it against live declarations. " \
        "Refuses comment-sourced, missing, ambiguous, or non-resolving edges. Requires confirmation."
    end

    # Removing a dependency declaration changes dependency-graph semantics,
    # so unlike plain issue edits this tool always keeps the manual
    # confirmation click even when auto-approve is enabled (RDR-028).
    def self.auto_approve_eligible? = false

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, occurrence: { type: "string" },
        confirmed: { type: "boolean" } }, required: %w[project_id occurrence confirmed] }
    end

    # @spec AUTO-PICK-QUEUE-021
    def perform(project_id:, occurrence:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to repair a dependency cycle" unless confirmed

      project = project_for(project_id)
      cycle = Issues::DependencyCycles.call(account: project.account).find { |candidate| candidate.occurrence == occurrence }
      raise ArgumentError, "Dependency cycle occurrence is no longer present" unless cycle

      authorize declaring_project_for(cycle), :manage_issues?, policy_class: ProjectPolicy
      CycleRepairs::Apply.call(cycle:, actor: current_user).payload
    end

    private

    def declaring_project_for(cycle)
      cycle.path.first.project
    end
  end
end
