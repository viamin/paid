# frozen_string_literal: true

module Tools
  class PrioritizeCodingRetry < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "prioritize_coding_retry"
    def self.write_operation? = true
    # @spec QUEUE-TIER-008
    def self.mcp_available? = true
    def self.description
      "Prioritize one existing unclaimed automatic coding retry without changing its execution authority or retry history. " \
        "All scheduler eligibility and capacity checks remain in force. Requires confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, agent_run_id: { type: "integer" }, confirmed: { type: "boolean" } }, required: %w[project_id agent_run_id confirmed] }
    end

    def perform(project_id:, agent_run_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to prioritize a coding retry" unless confirmed

      project = project_for(project_id)
      agent_run = project.agent_runs.find(agent_run_id)
      changed = AgentRuns::PrioritizeCodingRetry.call(agent_run:, actor: current_user)
      raise ArgumentError, "The coding retry is no longer eligible for priority" unless changed

      { agent_run_id: agent_run.id, status: agent_run.status, priority_requested: true }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
