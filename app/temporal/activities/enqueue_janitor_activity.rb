# frozen_string_literal: true

module Activities
  # Enqueues a janitor job as a second-chance cleanup pass after a workflow
  # completes or fails. The janitor job itself runs outside the Temporal
  # workflow/activity lifecycle so it can recover resources that in-workflow
  # cleanup activities might miss; this activity only schedules that job.
  class EnqueueJanitorActivity < BaseActivity
    activity_name "EnqueueJanitor"

    def execute(input)
      agent_run_id = input[:agent_run_id]

      AgentRunResourceJanitorJob.perform_later(agent_run_id)

      logger.info(
        message: "agent_execution.janitor_enqueued",
        agent_run_id: agent_run_id
      )

      { agent_run_id: agent_run_id }
    end
  end
end
