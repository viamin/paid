# frozen_string_literal: true

# index_issue_merge_subscriptions_on_dedup covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5585 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :issue_merge_subscriptions, name: "index_issue_merge_subscriptions_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :issue_merge_subscriptions, [ :issue_id ],
      name: "index_issue_merge_subscriptions_on_issue_id", algorithm: :concurrently
  end
end
