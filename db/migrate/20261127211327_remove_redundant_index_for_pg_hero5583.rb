# frozen_string_literal: true

# index_intent_conformance_verdicts_on_issue_head_evaluated_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5583 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_verdicts, name: "index_intent_conformance_verdicts_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_verdicts, [ :issue_id ],
      name: "index_intent_conformance_verdicts_on_issue_id", algorithm: :concurrently
  end
end
