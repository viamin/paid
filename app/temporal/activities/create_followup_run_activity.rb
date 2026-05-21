# frozen_string_literal: true

module Activities
  class CreateFollowupRunActivity < BaseActivity
    activity_name "CreateFollowupRun"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      goal = input.fetch(:goal)

      result = track_phase(
        agent_run_id: agent_run.id,
        phase_key: "create_followup_run",
        phase_group: "post",
        agent_run: agent_run,
        metadata: { goal: goal }
      ) do
        QueueAgentRunActivity.new.execute(queue_input(agent_run, goal))
      end

      {
        agent_run_id: agent_run.id,
        followup_agent_run_id: result[:agent_run_id],
        goal: goal,
        queued: result.fetch(:queued, false),
        duplicate: result.fetch(:duplicate, false),
        cross_goal: result.fetch(:cross_goal, false)
      }
    end

    private

    def queue_input(agent_run, goal)
      {
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id,
        goal: goal,
        auto_pick: true,
        initiating_user_id: agent_run.initiating_user_id,
        runner_id: agent_run.runner_id
      }.compact
    end
  end
end
