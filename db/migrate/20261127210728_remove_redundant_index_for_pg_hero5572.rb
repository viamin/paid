# frozen_string_literal: true

# idx_on_account_id_service_key_name_e4c03e1ea7 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5572 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :integration_credentials, name: "index_integration_credentials_on_account_id_and_service_key", algorithm: :concurrently
  end

  def down
    add_index :integration_credentials, [ :account_id, :service_key ],
      name: "index_integration_credentials_on_account_id_and_service_key", algorithm: :concurrently
  end
end
