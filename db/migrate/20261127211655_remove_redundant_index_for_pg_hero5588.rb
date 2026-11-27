# frozen_string_literal: true

# idx_knowledge_artifacts_project_status_identifier covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5588 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_artifacts, name: "index_knowledge_artifacts_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :knowledge_artifacts, [ :project_id ],
      name: "index_knowledge_artifacts_on_project_id", algorithm: :concurrently
  end
end
