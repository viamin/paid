# frozen_string_literal: true

class AddTriggerTypeToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :trigger_type, :string, limit: 50, default: "automatic", null: false
  end
end
