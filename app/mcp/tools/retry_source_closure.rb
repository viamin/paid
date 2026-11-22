# frozen_string_literal: true

module Tools
  class RetrySourceClosure < BaseTool
    authorize :retry?, ->(args) { run_for(args.fetch(:agent_run_id)) }

    def self.tool_name = "retry_source_closure"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.description
      "Retry source-closure post-processing on a waiting agent run without rerunning coding. Requires confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          agent_run_id: { type: "integer", description: "The existing waiting agent run ID" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[agent_run_id confirmed]
      }
    end

    # @spec PARTIAL-CLOSEOUT-045 PARTIAL-CLOSEOUT-060
    def perform(agent_run_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to retry source closure" unless confirmed

      run = run_for(agent_run_id).reload
      raise ArgumentError, "This run is not waiting for source-closure recovery" unless run.waiting_recovery?

      job = SourceClosureRecoveryJob.perform_later(run.id, operator_id: user.id)
      unless job && job.successfully_enqueued?
        raise ArgumentError, "Source-closure recovery could not be queued. Please try again."
      end

      { agent_run_id: run.id, status: run.status, queued: true }
    end

    private

    def run_for(id)
      @runs_by_id ||= {}
      @runs_by_id[id] ||= policy_scope(AgentRun).find(id)
    end
  end
end
