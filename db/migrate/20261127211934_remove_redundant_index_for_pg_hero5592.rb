# frozen_string_literal: true

# index_knowledge_recommendations_on_project_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5592 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_recommendations, name: "index_knowledge_recommendations_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :knowledge_recommendations, [ :project_id ],
      name: "index_knowledge_recommendations_on_project_id", algorithm: :concurrently
  end
end
