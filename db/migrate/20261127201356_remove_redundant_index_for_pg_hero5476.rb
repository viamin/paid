# frozen_string_literal: true

# index_billing_periods_on_account_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5476 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :billing_periods, name: "index_billing_periods_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :billing_periods, [ :account_id ],
      name: "index_billing_periods_on_account_id", algorithm: :concurrently
  end
end
