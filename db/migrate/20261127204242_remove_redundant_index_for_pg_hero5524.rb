# frozen_string_literal: true

# idx_design_artifact_associations_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5524 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :design_artifact_associations, name: "index_design_artifact_associations_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :design_artifact_associations, [ :project_id ],
      name: "index_design_artifact_associations_on_project_id", algorithm: :concurrently
  end
end
