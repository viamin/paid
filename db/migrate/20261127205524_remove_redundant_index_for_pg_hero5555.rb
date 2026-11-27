# frozen_string_literal: true

# idx_on_feature_intent_facet_id_name_f5a6e56431 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5555 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_facet_directions, name: "idx_on_feature_intent_facet_id_b98fb4f64a", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_facet_directions, [ :feature_intent_facet_id ],
      name: "idx_on_feature_intent_facet_id_b98fb4f64a", algorithm: :concurrently
  end
end
