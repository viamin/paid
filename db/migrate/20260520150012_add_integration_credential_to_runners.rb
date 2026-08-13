# frozen_string_literal: true

class AddIntegrationCredentialToRunners < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :runners, :integration_credential, null: true, index: { algorithm: :concurrently }
    add_foreign_key :runners, :integration_credentials, on_delete: :restrict, validate: false
    validate_foreign_key :runners, :integration_credentials
  end
end
