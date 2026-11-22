# frozen_string_literal: true

module Activities
  class ParkSourceClosureRecoveryActivity < BaseActivity
    activity_name "ParkSourceClosureRecovery"

    def execute(input) # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045 PARTIAL-CLOSEOUT-061
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      PartialCloseouts::SourceClosureRecovery.park!(agent_run: agent_run,
        category: input.fetch(:category), attempts: input.fetch(:attempts, 3))
      retry_at = agent_run.reload.reconciliation.dig(PartialCloseouts::SourceClosureRecovery::KEY, "next_retry_at")
      enqueue_retry(agent_run) if input[:auto_retry] != false && retry_at.present?
      { agent_run_id: agent_run.id, waiting: true }
    end

    private

    def enqueue_retry(agent_run)
      SourceClosureRecoveryJob.set(wait: PartialCloseouts::SourceClosureRecovery::RETRY_DELAY).perform_later(agent_run.id)
    end
  end
end
