# frozen_string_literal: true

module Tools
  class RepairCycleAnalysis < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "repair_cycle_analysis"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.description
      "Apply one reviewed dependency-cycle declaration removal through the trusted human GitHub client. " \
        "Requires confirmation and returns the bounded repair outcome."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "Project owning the cycle analysis" },
          agent_run_id: { type: "integer", description: "Completed cycle-analysis run ID" },
          candidate_index: { type: "integer", description: "Zero-based candidate index from the analysis recommendation" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id agent_run_id candidate_index confirmed]
      }
    end

    # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
    def perform(project_id:, agent_run_id:, candidate_index:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to repair a cycle analysis" unless confirmed
      raise ArgumentError, "Candidate index must be non-negative" if candidate_index.to_i.negative?

      project = project_for(project_id)
      run = policy_scope(AgentRun).where(project_id: project.id, goal: AgentRun::CYCLE_ANALYSIS_GOAL).find(agent_run_id)
      candidate = run.verification_result.fetch(CycleAnalyses::RESULT_KEY).fetch("recommendation").fetch("candidates").fetch(candidate_index)
      result = CycleAnalyses::Repair.call(agent_run: run, candidate:, actor: current_user)

      { agent_run_id: run.id, candidate_index:, status: result.status.to_s, message: result.message, success: result.success? }
    rescue IndexError
      raise ArgumentError, "Cycle analysis candidate is no longer available"
    rescue KeyError => error
      raise ArgumentError, "Cycle analysis result is incomplete: #{error.message}"
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
