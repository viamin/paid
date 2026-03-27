# frozen_string_literal: true

class AddAutoPickToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :auto_pick, :boolean, default: false, null: false
  end
end
