# frozen_string_literal: true

# index_agent_run_anomalies_on_project_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5449 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_run_anomalies, name: "index_agent_run_anomalies_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :agent_run_anomalies, [ :project_id ],
      name: "index_agent_run_anomalies_on_project_id", algorithm: :concurrently
  end
end
