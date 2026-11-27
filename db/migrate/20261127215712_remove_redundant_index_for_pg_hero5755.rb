# frozen_string_literal: true

# index_preview_sessions_on_project_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5755 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :preview_sessions, name: "index_preview_sessions_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :preview_sessions, [ :project_id ],
      name: "index_preview_sessions_on_project_id", algorithm: :concurrently
  end
end
