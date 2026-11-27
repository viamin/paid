# frozen_string_literal: true

# index_facet_assessments_direction_revision covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5550 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_facet_assessments, name: "idx_on_feature_intent_facet_direction_id_3af4455063", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_facet_assessments, [ :feature_intent_facet_direction_id ],
      name: "idx_on_feature_intent_facet_direction_id_3af4455063", algorithm: :concurrently
  end
end
