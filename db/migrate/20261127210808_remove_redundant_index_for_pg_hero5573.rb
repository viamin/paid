# frozen_string_literal: true

# index_intent_conformance_decisions_on_issue_action_head covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5573 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_decisions, name: "index_intent_conformance_decisions_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_decisions, [ :issue_id ],
      name: "index_intent_conformance_decisions_on_issue_id", algorithm: :concurrently
  end
end
