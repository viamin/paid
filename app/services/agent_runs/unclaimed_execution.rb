# frozen_string_literal: true

module AgentRuns
  # Identifies persisted execution ownership that a priority request must not take over.
  # @spec QUEUE-TIER-007 QUEUE-TIER-008 QUEUE-TIER-010
  class UnclaimedExecution
    def self.eligible?(agent_run)
      agent_run.temporal_workflow_id.blank? && agent_run.started_at.blank? &&
        agent_run.container_id.blank? && agent_run.runner_handle.blank? &&
        agent_run.worktree_path.blank? && agent_run.service_container_ids.blank? &&
        agent_run.worktree.nil?
    end
  end
end
