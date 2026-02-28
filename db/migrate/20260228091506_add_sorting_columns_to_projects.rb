# frozen_string_literal: true

class AddSortingColumnsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_agent_run_at, :datetime
    add_column :projects, :last_github_activity_at, :datetime
    add_index :projects, :last_agent_run_at
    add_index :projects, :last_github_activity_at

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE projects SET last_agent_run_at = (
            SELECT MAX(agent_runs.created_at) FROM agent_runs WHERE agent_runs.project_id = projects.id
          )
        SQL
        execute <<~SQL
          UPDATE projects SET last_github_activity_at = (
            SELECT MAX(issues.github_updated_at) FROM issues WHERE issues.project_id = projects.id
          )
        SQL
      end
    end
  end
end
