# frozen_string_literal: true

class AddAutoPickToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_runs, :auto_pick, :boolean, default: false, null: false

    execute <<~SQL
      UPDATE agent_runs
      SET auto_pick = TRUE
      WHERE trigger_type = 'automatic'
        AND source_pull_request_number IS NULL
        AND issue_id IS NOT NULL;
    SQL
  end

  def down
    remove_column :agent_runs, :auto_pick
  end
end
