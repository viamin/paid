# frozen_string_literal: true

# index_context_intake_sessions_on_project_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5502 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :context_intake_sessions, name: "index_context_intake_sessions_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :context_intake_sessions, [ :project_id ],
      name: "index_context_intake_sessions_on_project_id", algorithm: :concurrently
  end
end
