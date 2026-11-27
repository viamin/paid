# frozen_string_literal: true

# index_agent_runs_on_project_status_completed_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5454 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_runs, name: "index_agent_runs_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :agent_runs, [ :project_id ],
      name: "index_agent_runs_on_project_id", algorithm: :concurrently
  end
end
