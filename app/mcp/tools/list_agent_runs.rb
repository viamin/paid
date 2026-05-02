# frozen_string_literal: true

module Tools
  class ListAgentRuns < BaseTool
    def self.tool_name = "list_agent_runs"

    def self.description
      "List recent agent runs with optional status and project filters."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "Filter by project ID" },
          status: { type: "string", description: "Filter by status", enum: AgentRun::STATUSES },
          limit: { type: "integer", description: "Max results (default 20)", default: 20 }
        }
      }
    end

    def call(project_id: nil, status: nil, limit: 20)
      runs = policy_scope(AgentRun)
      runs = runs.where(project_id:) if project_id.present?
      runs = runs.by_status(status) if status.present?
      runs = runs.recent.limit(limit.to_i.clamp(1, 100))

      runs.map do |run|
        {
          id: run.id,
          project_id: run.project_id,
          issue_id: run.issue_id,
          status: run.status,
          goal: run.goal,
          pull_request_url: run.pull_request_url,
          trigger_type: run.trigger_type,
          created_at: run.created_at
        }
      end
    end
  end
end
