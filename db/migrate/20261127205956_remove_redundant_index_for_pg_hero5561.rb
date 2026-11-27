# frozen_string_literal: true

# idx_feature_intent_issue_dependencies_unique covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5561 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :feature_intent_issue_dependencies, name: "idx_on_feature_intent_issue_id_32c718a1ab", algorithm: :concurrently
  end

  def down
    add_index :feature_intent_issue_dependencies, [ :feature_intent_issue_id ],
      name: "idx_on_feature_intent_issue_id_32c718a1ab", algorithm: :concurrently
  end
end
