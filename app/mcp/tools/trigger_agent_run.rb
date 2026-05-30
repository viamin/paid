# frozen_string_literal: true

module Tools
  class TriggerAgentRun < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "trigger_agent_run"
    def self.write_operation? = true

    def self.description
      "Start an agent run on an issue. Requires explicit confirmation."
    end

    def self.available_to?(user:)
      run_agent_available_to?(user:)
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

    def perform(project_id:, issue_id:, confirmed: false, goal: "create_pr")
      raise ArgumentError, "Confirmation required: set confirmed=true to trigger an agent run" unless confirmed

      project = project_for(project_id)

      issue = project.issues.find(issue_id)

      runner_id, agent_type = AgentRuns::RunnerResolver.call(
        project: project,
        goal: goal
      )

      run = AgentRun.create!(
        project: project,
        issue: issue,
        initiating_user: current_user,
        runner_id: runner_id,
        agent_type: agent_type,
        goal: goal,
        status: "queued",
        trigger_type: "manual"
      )

      ProcessRunQueueJob.perform_later

      {
        id: run.id,
        status: run.status,
        goal: run.goal,
        issue_id: run.issue_id,
        project_id: run.project_id,
        created_at: run.created_at
      }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless duplicate_active_issue_run?(e)

      raise ArgumentError, "An agent run is already queued or in progress for this issue"
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def duplicate_active_issue_run?(error)
      (error.cause&.message || error.message).include?("idx_agent_runs_unique_active_issue")
    end
  end
end
