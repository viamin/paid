# frozen_string_literal: true

# index_agent_run_logs_on_agent_run_id_and_log_type covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5450 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_run_logs, name: "index_agent_run_logs_on_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :agent_run_logs, [ :agent_run_id ],
      name: "index_agent_run_logs_on_agent_run_id", algorithm: :concurrently
  end
end
