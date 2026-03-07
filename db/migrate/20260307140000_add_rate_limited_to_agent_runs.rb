# frozen_string_literal: true

class AddRateLimitedToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :rate_limited_until, :datetime
  end
end
