# @spec QUEUE-TIER-010
class AddOperatorFirstImplementationPriorityRequestedAtToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :operator_first_implementation_priority_requested_at, :datetime,
      comment: "Explicit operator scheduling request for an existing automatic first implementation; execution authority remains unchanged."
  end
end
