# frozen_string_literal: true

class AddAgentRunsCountToProjects < ActiveRecord::Migration[8.1]
  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  class MigrationAgentRun < ApplicationRecord
    self.table_name = "agent_runs"
  end

  def change
    add_column :projects, :agent_runs_count, :integer, default: 0, null: false,
      comment: "Counter cache for total agent runs"
    add_column :projects, :completed_agent_runs_count, :integer, default: 0, null: false,
      comment: "Counter cache for completed agent runs"

    reversible do |dir|
      dir.up do
        MigrationProject.reset_column_information

        TenantContext.with_system_access do
          MigrationProject.unscoped.in_batches(of: 1_000) do |relation|
            project_ids = relation.pluck(:id)
            counts_by_project_id = MigrationAgentRun.unscoped
              .where(project_id: project_ids)
              .group(:project_id)
              .count
            completed_counts_by_project_id = MigrationAgentRun.unscoped
              .where(project_id: project_ids, status: "completed")
              .group(:project_id)
              .count

            relation.each do |project|
              project.update_columns(
                agent_runs_count: counts_by_project_id.fetch(project.id, 0),
                completed_agent_runs_count: completed_counts_by_project_id.fetch(project.id, 0)
              )
            end
          end
        end
      end
    end
  end
end
