# frozen_string_literal: true

# idx_on_project_id_responsible_phase_049615cd29 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5570 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :inbox_request_ownerships, name: "index_inbox_request_ownerships_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :inbox_request_ownerships, [ :project_id ],
      name: "index_inbox_request_ownerships_on_project_id", algorithm: :concurrently
  end
end
