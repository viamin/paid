# frozen_string_literal: true

class ExcludeCloseoutVerificationFromActiveRunIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ACTIVE_STATUSES = %w[queued pending running paused waiting_recovery].freeze

  def up
    replace_indexes(excluding_closeout_verification: true)
  end

  def down
    replace_indexes(excluding_closeout_verification: false)
  end

  private

  def replace_indexes(excluding_closeout_verification:)
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_issue", algorithm: :concurrently
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently
    add_active_index(:issue_id, "idx_agent_runs_unique_active_issue", excluding_closeout_verification:)
    add_active_index(:source_pull_request_number, "idx_agent_runs_unique_active_pr", excluding_closeout_verification:)
  end

  def add_active_index(column, name, excluding_closeout_verification:)
    statuses = ACTIVE_STATUSES.map { |status| connection.quote(status) }.join(", ")
    predicate = "#{column} IS NOT NULL AND status IN (#{statuses})"
    predicate += " AND goal <> 'closeout_verification'" if excluding_closeout_verification
    add_index :agent_runs, [ :project_id, column, :goal ], unique: true,
      where: predicate, name:, algorithm: :concurrently
  end
end
