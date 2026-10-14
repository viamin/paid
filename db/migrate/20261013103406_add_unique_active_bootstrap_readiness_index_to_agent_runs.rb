# frozen_string_literal: true

# Backstop for the in-application exists-check in
# Projects::AgentRunsController#bootstrap_readiness: bootstrap runs are
# issue-less and PR-less, so the existing partial unique indexes on
# (project_id, issue_id, goal) and (project_id, source_pull_request_number,
# goal) do not cover them. Without this index, two concurrent requests can
# both pass the exists check before either creates its queued run, leaving
# the project with multiple unfinished bootstrap attempts. The application
# also serializes the check-and-create with a project row lock; this index
# guarantees the same invariant even if a caller forgets the lock.
# @spec PROJECT-READINESS-007
class AddUniqueActiveBootstrapReadinessIndexToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :agent_runs, :project_id,
      unique: true,
      where: "goal = 'bootstrap_readiness' AND status IN ('queued', 'running', 'paused', 'rate_limited')",
      name: "idx_agent_runs_unique_active_bootstrap_readiness",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_bootstrap_readiness",
      algorithm: :concurrently,
      if_exists: true
  end
end
