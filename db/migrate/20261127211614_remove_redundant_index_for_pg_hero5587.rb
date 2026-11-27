# frozen_string_literal: true

# index_knowledge_artifacts_on_collector_run_id_and_content_hash covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5587 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_artifacts, name: "index_knowledge_artifacts_on_collector_run_id", algorithm: :concurrently
  end

  def down
    add_index :knowledge_artifacts, [ :collector_run_id ],
      name: "index_knowledge_artifacts_on_collector_run_id", algorithm: :concurrently
  end
end
