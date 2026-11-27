# frozen_string_literal: true

# idx_intent_review_schedules_unique_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5578 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_review_schedules, name: "index_intent_conformance_review_schedules_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_review_schedules, [ :issue_id ],
      name: "index_intent_conformance_review_schedules_on_issue_id", algorithm: :concurrently
  end
end
