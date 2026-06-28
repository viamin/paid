# frozen_string_literal: true

class CreateRunnerCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :runner_credentials do |t|
      t.references :account, null: false, foreign_key: true
      t.references :runner, null: false, foreign_key: true, index: false
      t.string :token, null: false, comment: "Encrypted authentication token (e.g., claude setup-token)"
      t.boolean :long_lived, default: false, null: false, comment: "Whether this is a long-lived token that does not need periodic refresh"
      t.references :created_by, foreign_key: { to_table: :users }, null: true
      t.datetime :revoked_at, comment: "Timestamp when credential was revoked"
      t.jsonb :log_data, comment: "Logidze change tracking"

      t.timestamps
    end

    add_index :runner_credentials, [ :runner_id ],
      unique: true,
      where: "revoked_at IS NULL",
      name: "index_runner_credentials_on_active_runner_id"
    add_index :runner_credentials, [ :account_id, :created_at ]
  end
end
