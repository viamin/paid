# frozen_string_literal: true

# index_decision_record_links_on_record_and_linkable_and_type covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5511 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :decision_record_links, name: "index_decision_record_links_on_decision_record_id", algorithm: :concurrently
  end

  def down
    add_index :decision_record_links, [ :decision_record_id ],
      name: "index_decision_record_links_on_decision_record_id", algorithm: :concurrently
  end
end
