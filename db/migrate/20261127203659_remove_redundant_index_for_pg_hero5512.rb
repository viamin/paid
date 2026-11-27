# frozen_string_literal: true

# index_decision_records_on_project_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5512 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :decision_records, name: "index_decision_records_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :decision_records, [ :project_id ],
      name: "index_decision_records_on_project_id", algorithm: :concurrently
  end
end
