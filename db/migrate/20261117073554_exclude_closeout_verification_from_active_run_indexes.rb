# frozen_string_literal: true

# @spec STAGED-CLOSEOUT-ADOPTION-008 STAGED-CLOSEOUT-ADOPTION-009
class ExcludeCloseoutVerificationFromActiveRunIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ACTIVE_STATUSES = %w[queued pending running paused waiting_recovery].freeze

  def up
    replace_indexes(excluding_closeout_verification: true)
  end

  def down
    if legacy_index_conflicts?
      raise ActiveRecord::IrreversibleMigration, <<~MESSAGE.squish
        The legacy active-run indexes cannot represent the admitted closeout-verification rows.
        Before retrying rollback, retain at most one active closeout-verification run for each
        project/issue/goal and project/source-PR/goal key by completing, cancelling, or removing duplicates.
      MESSAGE
    end

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

  def legacy_index_conflicts?
    columns = %w[issue_id source_pull_request_number]
    conflict_queries = columns.map { |column| legacy_index_conflict_query(column) }.join(" UNION ALL ")
    connection.select_value("SELECT 1 FROM (#{conflict_queries}) conflicts LIMIT 1").present?
  end

  def legacy_index_conflict_query(column)
    statuses = ACTIVE_STATUSES.map { |status| connection.quote(status) }.join(", ")
    <<~SQL.squish
      SELECT 1 FROM agent_runs
      WHERE goal = 'closeout_verification' AND #{column} IS NOT NULL AND status IN (#{statuses})
      GROUP BY project_id, #{column}, goal HAVING COUNT(*) > 1
    SQL
  end
end
