# frozen_string_literal: true

# @spec QUEUE-TIER-011
class AddDependencyBottleneckPriorityRequestedAtToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :dependency_bottleneck_priority_requested_at, :datetime,
      comment: "Current synced dependency evidence that this fresh coding run unblocks active delivery; cleared when the evidence is stale."
  end
end
