# frozen_string_literal: true

# idx_on_feature_intent_facet_id_evidence_revision_06283b242e covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5557 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_facet_evidence, name: "index_feature_intent_facet_evidence_on_feature_intent_facet_id", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_facet_evidence, [ :feature_intent_facet_id ],
      name: "index_feature_intent_facet_evidence_on_feature_intent_facet_id", algorithm: :concurrently
  end
end
