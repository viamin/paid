# frozen_string_literal: true

module Activities
  class ParkSourceClosureRecoveryActivity < BaseActivity
    activity_name "ParkSourceClosureRecovery"

    def execute(input) # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      PartialCloseouts::SourceClosureRecovery.park!(agent_run: agent_run,
        category: input.fetch(:category), attempts: input.fetch(:attempts, 3))
      enqueue_retry(agent_run) unless input[:auto_retry] == false
      { agent_run_id: agent_run.id, waiting: true }
    end

    private

    def enqueue_retry(agent_run)
      SourceClosureRecoveryJob.set(wait: PartialCloseouts::SourceClosureRecovery::RETRY_DELAY).perform_later(agent_run.id)
    end
  end
end
