# frozen_string_literal: true

# index_explicit_preferences_on_project_id_and_scope covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5538 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :explicit_preferences, name: "index_explicit_preferences_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :explicit_preferences, [ :project_id ],
      name: "index_explicit_preferences_on_project_id", algorithm: :concurrently
  end
end
