# frozen_string_literal: true

# index_maintenance_findings_on_recurring_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5608 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :maintenance_findings, name: "index_maintenance_findings_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :maintenance_findings, [ :project_id ],
      name: "index_maintenance_findings_on_project_id", algorithm: :concurrently
  end
end
