# frozen_string_literal: true

class AddGoalToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :goal, :string, limit: 50, default: "create_pr", null: false
    add_column :agent_runs, :created_issue_url, :string, limit: 500
    add_column :agent_runs, :created_issue_number, :integer

    add_index :agent_runs, [:project_id, :goal]
  end
end
