# frozen_string_literal: true

class AddPriorityTierToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :priority_tier, :string, limit: 10
  end
end
