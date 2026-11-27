# frozen_string_literal: true

# index_notification_rule_states_on_dedup covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5667 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :notification_rule_states, name: "index_notification_rule_states_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :notification_rule_states, [ :account_id ],
      name: "index_notification_rule_states_on_account_id", algorithm: :concurrently
  end
end
