# frozen_string_literal: true

class AddContainerIdToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :container_id, :string, limit: 128
  end
end
