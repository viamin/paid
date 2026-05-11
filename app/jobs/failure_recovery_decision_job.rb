# frozen_string_literal: true

# Persists failure-recovery decisions after an AgentRun reaches a terminal
# state. Running this asynchronously keeps the AgentRun commit path aligned
# with adjacent callbacks that enqueue background work.
class FailureRecoveryDecisionJob < ApplicationJob
  queue_as :default

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    Coordination::FailureRecovery.call(agent_run: agent_run)
  end
end
