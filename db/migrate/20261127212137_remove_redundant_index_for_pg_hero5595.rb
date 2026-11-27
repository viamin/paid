# frozen_string_literal: true

# index_knowledge_usage_stats_on_project_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5595 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_usage_stats, name: "index_knowledge_usage_stats_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :knowledge_usage_stats, [ :project_id ],
      name: "index_knowledge_usage_stats_on_project_id", algorithm: :concurrently
  end
end
