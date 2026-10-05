# frozen_string_literal: true

class AddPartialCloseoutReconciliationToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :reconciliation, :jsonb, null: false, default: {},
      comment: "Durable replay state for partial PR closeout gap reconciliation."
  end
end
