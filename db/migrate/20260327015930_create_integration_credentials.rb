# frozen_string_literal: true

class CreateIntegrationCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :integration_credentials do |t|
      t.references :account, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :service_key, null: false
      t.string :category, null: false
      t.string :auth_kind, null: false
      t.text :secret, null: false
      t.datetime :expires_at
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :integration_credentials, [ :account_id, :service_key, :name ], unique: true
    add_index :integration_credentials, [ :account_id, :category ]
    add_index :integration_credentials, [ :account_id, :service_key ]
    add_index :integration_credentials, [ :account_id, :revoked_at ]
  end
end
