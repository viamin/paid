# frozen_string_literal: true

class AddParallelExecutionSupport < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :parent_workflow_id, :string, limit: 255
    add_index :agent_runs, :parent_workflow_id

    add_column :user_settings, :max_parallel_agents_per_project, :integer, default: 3, null: false
  end
end
