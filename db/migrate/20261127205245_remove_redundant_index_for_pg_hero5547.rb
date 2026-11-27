# frozen_string_literal: true

# index_feature_intent_approval_revisions_unique_revision covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5547 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_approval_revisions, name: "index_feature_intent_approval_revisions_on_feature_intent_id", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_approval_revisions, [ :feature_intent_id ],
      name: "index_feature_intent_approval_revisions_on_feature_intent_id", algorithm: :concurrently
  end
end
