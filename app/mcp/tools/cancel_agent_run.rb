# frozen_string_literal: true

module Tools
  class CancelAgentRun < BaseTool
    authorize :cancel?, ->(args) { run_for(args.fetch(:agent_run_id)) }

    def self.tool_name = "cancel_agent_run"
    def self.write_operation? = true

    def self.description
      "Cancel an in-flight agent run. Requires explicit confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          agent_run_id: { type: "integer", description: "The agent run ID" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[agent_run_id confirmed]
      }
    end

    def perform(agent_run_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to cancel an agent run" unless confirmed

      run = run_for(agent_run_id)

      unless run.cancellable?
        raise ArgumentError, "Agent run is not cancellable (current status: #{run.status})"
      end

      unless run.cancel!
        return { id: run.id, status: run.reload.status, note: "Run already finished" }
      end

      AgentRunCancellationJob.perform_later(run.id)

      {
        id: run.id,
        status: run.status,
        cancelled_at: run.updated_at
      }
    end

    private

    def run_for(agent_run_id)
      @run = policy_scope(AgentRun).find(agent_run_id)
    end
  end
end
