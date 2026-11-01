# frozen_string_literal: true

module Tools
  class StartCycleAnalysis < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "start_cycle_analysis"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.description = "Start a bounded dependency-cycle repair run for one Inbox occurrence. The run may remove one verified GitHub dependency declaration only when strict safeguards pass. Requires confirmation and run authority for every represented project."

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, occurrence: { type: "string" }, confirmed: { type: "boolean" } }, required: %w[project_id occurrence confirmed] }
    end

    # @spec AUTO-PICK-QUEUE-016
    def perform(project_id:, occurrence:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to authorize a bounded cycle repair attempt" unless confirmed

      project = project_for(project_id)
      cycle = Issues::DependencyCycles.call(account: project.account).find { |candidate| candidate.occurrence == occurrence }
      raise ArgumentError, "Dependency cycle occurrence is no longer present" unless cycle

      cycle.project_ids.each { |id| authorize project.account.projects.find(id), :run_agent?, policy_class: ProjectPolicy }
      result = CycleAnalyses::Start.call(cycle:, actor: current_user)
      { id: result.agent_run&.id, status: result.status, message: result.message }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
