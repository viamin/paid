# frozen_string_literal: true

# @spec PARTIAL-CLOSEOUT-044
class IncludeWaitingRecoveryInActiveRunIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ACTIVE_STATUSES = %w[queued pending running paused waiting_recovery].freeze
  PREVIOUS_ACTIVE_STATUSES = %w[queued pending running paused].freeze

  def up
    replace_indexes(ACTIVE_STATUSES)
  end

  def down
    replace_indexes(PREVIOUS_ACTIVE_STATUSES)
  end

  private

  def replace_indexes(statuses)
    remove_active_indexes
    add_active_indexes(statuses)
  end

  def remove_active_indexes
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_issue", algorithm: :concurrently
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently
  end

  def add_active_indexes(statuses)
    status_list = statuses.map { |status| connection.quote(status) }.join(", ")

    add_index :agent_runs, [ :project_id, :issue_id, :goal ], unique: true,
      where: "issue_id IS NOT NULL AND status IN (#{status_list})",
      name: "idx_agent_runs_unique_active_issue", algorithm: :concurrently
    add_index :agent_runs, [ :project_id, :source_pull_request_number, :goal ], unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN (#{status_list})",
      name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently
  end
end
