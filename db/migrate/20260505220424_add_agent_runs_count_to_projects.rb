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
          SET agent_runs_count = sub.total,
              completed_agent_runs_count = sub.completed
          FROM (
            SELECT project_id,
                   COUNT(*) AS total,
                   COUNT(*) FILTER (WHERE status = 'completed') AS completed
            FROM agent_runs
            GROUP BY project_id
          ) sub
          WHERE projects.id = sub.project_id
        SQL
      end
    end
  end
end
