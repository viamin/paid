# frozen_string_literal: true

class ChangeIntegrationCredentialNameUniquenessScope < ActiveRecord::Migration[8.1]
  def change
    remove_index :integration_credentials, [ :account_id, :name ], unique: true
    add_index :integration_credentials, [ :account_id, :service_key, :name ], unique: true
  end
end
