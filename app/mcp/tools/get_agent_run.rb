# frozen_string_literal: true

module Tools
  class GetAgentRun < BaseTool
    def self.tool_name = "get_agent_run"

    def self.description
      "Get details of an agent run including status, output summary, and timing."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          agent_run_id: { type: "integer", description: "The agent run ID" }
        },
        required: [ "agent_run_id" ]
      }
    end

    def call(agent_run_id:)
      run = policy_scope(AgentRun).find(agent_run_id)
      authorize run, :show?

      {
        id: run.id,
        project_id: run.project_id,
        issue_id: run.issue_id,
        status: run.status,
        goal: run.goal,
        agent_type: run.agent_type,
        branch_name: run.branch_name,
        pull_request_url: run.pull_request_url,
        pull_request_number: run.pull_request_number,
        error_message: run.error_message,
        iterations: run.iterations,
        duration_seconds: run.duration_seconds,
        tokens_input: run.tokens_input,
        tokens_output: run.tokens_output,
        cost_cents: run.cost_cents,
        trigger_type: run.trigger_type,
        started_at: run.started_at,
        completed_at: run.completed_at,
        created_at: run.created_at
      }
    end
  end
end
