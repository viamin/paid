# frozen_string_literal: true

class AddContainerRetainedUntilToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :container_retained_until, :datetime
  end
end
