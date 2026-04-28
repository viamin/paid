# frozen_string_literal: true

module Tools
  class TriggerAgentRun < BaseTool
    def self.tool_name = "trigger_agent_run"
    def self.write_operation? = true

    def self.description
      "Start an agent run on an issue. Requires explicit confirmation."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_id: { type: "integer", description: "The issue ID" },
          goal: { type: "string", description: "Run goal", enum: AgentRun::GOALS, default: "create_pr" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id issue_id confirmed]
      }
    end

    def call(project_id:, issue_id:, confirmed: false, goal: "create_pr")
      raise ArgumentError, "Confirmation required: set confirmed=true to trigger an agent run" unless confirmed

      project = policy_scope(Project).find(project_id)
      authorize project, :run_agent?, policy_class: ProjectPolicy

      issue = project.issues.find(issue_id)

      run = AgentRun.create!(
        project:,
        issue:,
        agent_type: "claude_code",
        goal:,
        status: "queued",
        trigger_type: "manual"
      )

      {
        id: run.id,
        status: run.status,
        goal: run.goal,
        issue_id: run.issue_id,
        project_id: run.project_id,
        created_at: run.created_at
      }
    end
  end
end
