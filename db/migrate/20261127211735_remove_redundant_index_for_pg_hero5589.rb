# frozen_string_literal: true

# idx_knowledge_audit_events_on_project_created_at_id covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5589 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :knowledge_audit_events, name: "index_knowledge_audit_events_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :knowledge_audit_events, [ :project_id ],
      name: "index_knowledge_audit_events_on_project_id", algorithm: :concurrently
  end
end
