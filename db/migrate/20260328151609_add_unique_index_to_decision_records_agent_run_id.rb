# frozen_string_literal: true

class AddUniqueIndexToDecisionRecordsAgentRunId < ActiveRecord::Migration[8.1]
  def change
    # Enforce 1:1 relationship between agent_run and decision_record at the DB level.
    # Partial index (WHERE NOT NULL) allows multiple records with NULL agent_run_id.
    # Also prevents duplicate records from Temporal activity retries.
    remove_index :decision_records, :agent_run_id
    add_index :decision_records, :agent_run_id, unique: true, where: "agent_run_id IS NOT NULL"
  end
end
