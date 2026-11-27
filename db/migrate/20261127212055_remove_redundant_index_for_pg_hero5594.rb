# frozen_string_literal: true

# idx_knowledge_usage_stats_unique covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5594 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_usage_stats, name: "index_knowledge_usage_stats_on_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :knowledge_usage_stats, [ :agent_run_id ],
      name: "index_knowledge_usage_stats_on_agent_run_id", algorithm: :concurrently
  end
end
