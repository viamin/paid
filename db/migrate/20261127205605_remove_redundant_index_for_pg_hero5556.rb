# frozen_string_literal: true

# index_facet_evidence_idempotency covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5556 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_facet_evidence, name: "index_feature_intent_facet_evidence_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_facet_evidence, [ :account_id ],
      name: "index_feature_intent_facet_evidence_on_account_id", algorithm: :concurrently
  end
end
