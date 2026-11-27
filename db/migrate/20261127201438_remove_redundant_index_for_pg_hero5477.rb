# frozen_string_literal: true

# index_billing_plans_on_account_id_and_active covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5477 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :billing_plans, name: "index_billing_plans_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :billing_plans, [ :account_id ],
      name: "index_billing_plans_on_account_id", algorithm: :concurrently
  end
end
