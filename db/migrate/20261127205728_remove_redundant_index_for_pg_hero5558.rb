# frozen_string_literal: true

# idx_on_account_id_feature_intent_id_22e10796a9 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5558 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_facets, name: "index_feature_intent_facets_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_facets, [ :account_id ],
      name: "index_feature_intent_facets_on_account_id", algorithm: :concurrently
  end
end
