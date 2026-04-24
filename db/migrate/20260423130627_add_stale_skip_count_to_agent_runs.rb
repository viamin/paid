# frozen_string_literal: true

class AddStaleSkipCountToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :stale_skip_count, :integer, default: 0, null: false
  end
end
