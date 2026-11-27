# frozen_string_literal: true

# index_issue_prerequisites_unique_mapping covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5562 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_issue_prerequisites, name: "idx_on_feature_intent_issue_prerequisite_mapping_id_d60e1156f7", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_issue_prerequisites, [ :feature_intent_issue_prerequisite_mapping_id ],
      name: "idx_on_feature_intent_issue_prerequisite_mapping_id_d60e1156f7", algorithm: :concurrently
  end
end
