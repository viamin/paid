# frozen_string_literal: true

module Tools
  # @spec AUTO-MERGE-011
  class ReassessConflictRepairScope < BaseTool
    authorize :retry?, ->(args) { run_for(args.fetch(:agent_run_id)) }

    def self.tool_name = "reassess_conflict_repair_scope"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.available_to?(user:) = run_agent_available_to?(user:)
    def self.description = "Reassess an immutable failed conflict-repair artifact without rerunning coding. Requires confirmation."

    def self.input_schema
      { type: "object", properties: {
        agent_run_id: { type: "integer", description: "The failed conflict-repair producer run" },
        confirmed: { type: "boolean", description: "Must be true to queue reassessment" }
      }, required: %w[agent_run_id confirmed] }
    end

    def perform(agent_run_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to reassess scope" unless confirmed

      run = run_for(agent_run_id).reload
      unless run.status == "failed" && run.focus == "merge_conflict" && run.result_commit_sha.present?
        raise ArgumentError, "This run is not an immutable failed conflict-repair artifact"
      end
      job = ReassessConflictRepairScopeJob.perform_later(run.id, requested_by_id: user.id)
      raise ArgumentError, "Scope reassessment could not be queued. Please try again." unless job && job.successfully_enqueued?

      { agent_run_id: run.id, status: run.status, queued: true }
    end

    private

    def run_for(id)
      @runs_by_id ||= {}
      @runs_by_id[id] ||= policy_scope(AgentRun).find(id)
    end
  end
end
