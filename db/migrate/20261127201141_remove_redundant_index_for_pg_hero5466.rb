# frozen_string_literal: true

# idx_on_project_id_status_309d97d26e covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5466 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :apple_verification_workflow_revisions, name: "index_apple_verification_workflow_revisions_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :apple_verification_workflow_revisions, [ :project_id ],
      name: "index_apple_verification_workflow_revisions_on_project_id", algorithm: :concurrently
  end
end
