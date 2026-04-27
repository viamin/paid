# frozen_string_literal: true

module Activities
  class CompleteIssueGoalActivity < BaseActivity
    activity_name "CompleteIssueGoal"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      return result(agent_run) if agent_run.finished?

      track_phase(agent_run_id: agent_run_id, phase_key: "complete_issue_goal", phase_group: "post", agent_run: agent_run) do
        if agent_run.created_issue_url.present?
          apply_priority_label(agent_run)

          completed = agent_run.complete!(
            issue_url: agent_run.created_issue_url,
            issue_number: agent_run.created_issue_number
          )
          if completed
            agent_run.log!("system", "Completed: issue ##{agent_run.created_issue_number} created")

            logger.info(
              message: "agent_execution.issue_goal_completed",
              agent_run_id: agent_run_id,
              issue_url: agent_run.created_issue_url
            )

            ProcessRunQueueJob.perform_later
          end

          { agent_run_id: agent_run_id, success: true, issue_created: true }
        else
          agent_run.log!("system", "Agent did not create an issue directly; falling back to platform issue creation")

          logger.info(
            message: "agent_execution.issue_goal_fallback",
            agent_run_id: agent_run_id
          )

          { agent_run_id: agent_run_id, success: true, issue_created: false }
        end
      end
    end

    private

    def apply_priority_label(agent_run)
      return if agent_run.priority_tier.blank?
      return if agent_run.created_issue_number.blank?

      project = agent_run.project
      label_name = project.priority_label_for(agent_run.priority_tier)
      return if label_name.blank?

      client = project.github_token.client
      client.add_labels_to_issue(project.full_name, agent_run.created_issue_number, [ label_name ])

      agent_run.log!("system", "Applied priority label: #{label_name}")

      logger.info(
        message: "agent_execution.priority_label_applied",
        agent_run_id: agent_run.id,
        issue_number: agent_run.created_issue_number,
        label: label_name
      )
    rescue GithubClient::Error => e
      agent_run.log!("system", "Failed to apply priority label #{label_name}: #{e.message}")

      logger.warn(
        message: "agent_execution.priority_label_failed",
        agent_run_id: agent_run.id,
        issue_number: agent_run.created_issue_number,
        label: label_name,
        error: e.message
      )

      raise
    end

    def result(agent_run)
      {
        agent_run_id: agent_run.id,
        success: agent_run.successful?,
        issue_created: agent_run.created_issue_url.present?,
        skipped: true,
        finished: true,
        cancelled: agent_run.status == "cancelled"
      }
    end
  end
end
