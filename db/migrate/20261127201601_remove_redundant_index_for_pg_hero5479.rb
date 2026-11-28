# frozen_string_literal: true

# index_change_intents_on_project_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5479 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :change_intents, name: "index_change_intents_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :change_intents, [ :project_id ],
      name: "index_change_intents_on_project_id", algorithm: :concurrently
  end
end
