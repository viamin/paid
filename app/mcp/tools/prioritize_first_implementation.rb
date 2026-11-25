# frozen_string_literal: true

module Tools
  class PrioritizeFirstImplementation < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "prioritize_first_implementation"
    def self.write_operation? = true
    # @spec QUEUE-TIER-010
    def self.mcp_available? = true
    def self.description
      "Prioritize one existing unclaimed automatic first implementation without changing execution authority. Requires confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)
    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, agent_run_id: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id agent_run_id confirmed] }
    end

    def perform(project_id:, agent_run_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to prioritize a first implementation" unless confirmed

      project = project_for(project_id)
      agent_run = project.agent_runs.find(agent_run_id)
      changed = AgentRuns::PrioritizeFirstImplementation.call(agent_run:, actor: current_user)
      raise ArgumentError, "The first implementation is no longer eligible for priority" unless changed

      { agent_run_id: agent_run.id, status: agent_run.status, priority_requested: true }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
