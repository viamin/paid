# frozen_string_literal: true

# idx_knowledge_chunks_project_status_artifact_sequence covers both redundant indexes.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5590 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_chunks, name: "index_knowledge_chunks_on_project_id", algorithm: :concurrently
    remove_index :knowledge_chunks, name: "index_knowledge_chunks_on_project_id_and_status", algorithm: :concurrently
  end

  def down
    add_index :knowledge_chunks, [ :project_id ],
      name: "index_knowledge_chunks_on_project_id", algorithm: :concurrently
    add_index :knowledge_chunks, [ :project_id, :status ],
      name: "index_knowledge_chunks_on_project_id_and_status", algorithm: :concurrently
  end
end
