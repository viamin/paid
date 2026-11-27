# frozen_string_literal: true

# idx_apple_attempts_project_status_created covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5464 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :apple_verification_attempts, name: "index_apple_verification_attempts_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :apple_verification_attempts, [ :project_id ],
      name: "index_apple_verification_attempts_on_project_id", algorithm: :concurrently
  end
end
