# frozen_string_literal: true

# index_maintenance_occurrences_on_report_and_finding covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5607 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :maintenance_finding_occurrences, name: "index_maintenance_finding_occurrences_on_maintenance_report_id", algorithm: :concurrently
  end

  def down
    add_index :maintenance_finding_occurrences, [ :maintenance_report_id ],
      name: "index_maintenance_finding_occurrences_on_maintenance_report_id", algorithm: :concurrently
  end
end
