# frozen_string_literal: true

class AddAgentRunsCountToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :agent_runs_count, :integer, default: 0, null: false,
      comment: "Counter cache for total agent runs"
    add_column :projects, :completed_agent_runs_count, :integer, default: 0, null: false,
      comment: "Counter cache for completed agent runs"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE projects
          SET agent_runs_count = (
            SELECT COUNT(*) FROM agent_runs WHERE agent_runs.project_id = projects.id
          ),
          completed_agent_runs_count = (
            SELECT COUNT(*) FROM agent_runs
            WHERE agent_runs.project_id = projects.id AND agent_runs.status = 'completed'
          )
        SQL
      end
    end
  end
end
