# frozen_string_literal: true

# idx_pending_install_claims_on_account_installation covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5753 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :pending_install_claims, name: "index_pending_install_claims_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :pending_install_claims, [ :account_id ],
      name: "index_pending_install_claims_on_account_id", algorithm: :concurrently
  end
end
