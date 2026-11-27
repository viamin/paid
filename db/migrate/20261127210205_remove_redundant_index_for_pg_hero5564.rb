# frozen_string_literal: true

# index_feature_intents_on_project_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5564 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intents, name: "index_feature_intents_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :feature_intents, [ :project_id ],
      name: "index_feature_intents_on_project_id", algorithm: :concurrently
  end
end
