# frozen_string_literal: true

class AddSortingColumnsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_agent_run_at, :datetime
    add_column :projects, :last_github_activity_at, :datetime

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE projects
          SET last_agent_run_at = sub.max_created_at
          FROM (
            SELECT project_id, MAX(created_at) AS max_created_at
            FROM agent_runs
            GROUP BY project_id
          ) AS sub
          WHERE projects.id = sub.project_id
        SQL
        execute <<~SQL
          UPDATE projects
          SET last_github_activity_at = sub.max_github_updated_at
          FROM (
            SELECT project_id, MAX(github_updated_at) AS max_github_updated_at
            FROM issues
            GROUP BY project_id
          ) AS sub
          WHERE projects.id = sub.project_id
        SQL
      end
    end

    add_index :projects, [ :account_id, :last_agent_run_at ]
    add_index :projects, [ :account_id, :last_github_activity_at ]
  end
end
