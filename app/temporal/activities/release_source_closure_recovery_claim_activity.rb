# frozen_string_literal: true

module Activities
  class ReleaseSourceClosureRecoveryClaimActivity < BaseActivity
    activity_name "ReleaseSourceClosureRecoveryClaim"

    def execute(input) # @spec PARTIAL-CLOSEOUT-045
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      released = PartialCloseouts::SourceClosureRecovery.release_claim!(
        agent_run:, attempts: input.fetch(:recovery_attempt)
      )
      { agent_run_id: agent_run.id, released: }
    end
  end
end
