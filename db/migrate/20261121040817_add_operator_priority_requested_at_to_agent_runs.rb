# frozen_string_literal: true

# @spec QUEUE-TIER-007
class AddOperatorPriorityRequestedAtToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :operator_priority_requested_at, :datetime,
      comment: "Explicit operator scheduling request for an existing audit; original execution authority remains unchanged."
  end
end
