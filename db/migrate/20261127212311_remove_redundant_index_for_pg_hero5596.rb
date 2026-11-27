# frozen_string_literal: true

# index_layered_verification_findings_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5596 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :layered_verification_findings, name: "index_layered_verification_findings_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :layered_verification_findings, [ :project_id ],
      name: "index_layered_verification_findings_on_project_id", algorithm: :concurrently
  end
end
