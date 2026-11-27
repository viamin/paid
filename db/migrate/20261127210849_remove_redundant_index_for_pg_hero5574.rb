# frozen_string_literal: true

# index_intent_resolutions_unique_issue_head covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5574 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_resolutions, name: "index_intent_conformance_resolutions_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_resolutions, [ :issue_id ],
      name: "index_intent_conformance_resolutions_on_issue_id", algorithm: :concurrently
  end
end
