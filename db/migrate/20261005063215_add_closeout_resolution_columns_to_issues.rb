# frozen_string_literal: true

# Concurrent indexes for the partial-closeout recovery lookups added by
# CreateIssueContinuationRequests (agent_runs.continuation_request_id for the
# dequeue recheck; issues.closeout_resolved_by_id for FK-style joins).
# @spec PARTIAL-CLOSEOUT-003 @spec PARTIAL-CLOSEOUT-005 @spec PARTIAL-CLOSEOUT-009
class AddCloseoutResolutionColumnsToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  AGENT_RUNS_INDEX = "index_agent_runs_on_continuation_request_id".freeze
  ISSUES_INDEX = "index_issues_on_closeout_resolved_by_id".freeze

  def up
    return unless column_exists?(:agent_runs, :continuation_request_id)

    unless index_exists?(:agent_runs, :continuation_request_id, name: AGENT_RUNS_INDEX)
      add_index :agent_runs, :continuation_request_id,
        name: AGENT_RUNS_INDEX,
        where: "continuation_request_id IS NOT NULL",
        algorithm: :concurrently
    end

    return unless column_exists?(:issues, :closeout_resolved_by_id)

    unless index_exists?(:issues, :closeout_resolved_by_id, name: ISSUES_INDEX)
      add_index :issues, :closeout_resolved_by_id,
        name: ISSUES_INDEX,
        where: "closeout_resolved_by_id IS NOT NULL",
        algorithm: :concurrently
    end
  end

  def down
    remove_index :issues, name: ISSUES_INDEX, if_exists: true, algorithm: :concurrently
    remove_index :agent_runs, name: AGENT_RUNS_INDEX, if_exists: true, algorithm: :concurrently
  end
end
