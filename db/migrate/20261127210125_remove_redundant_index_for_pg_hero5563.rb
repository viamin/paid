# frozen_string_literal: true

# index_feature_intent_issue_publications_on_task covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5563 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_issue_publications, name: "index_feature_intent_issue_publications_on_feature_intent_id", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_issue_publications, [ :feature_intent_id ],
      name: "index_feature_intent_issue_publications_on_feature_intent_id", algorithm: :concurrently
  end
end
