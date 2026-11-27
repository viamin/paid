# frozen_string_literal: true

# idx_egress_security_events_project_recent covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5533 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :egress_security_events, name: "index_egress_security_events_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :egress_security_events, [ :project_id ],
      name: "index_egress_security_events_on_project_id", algorithm: :concurrently
  end
end
