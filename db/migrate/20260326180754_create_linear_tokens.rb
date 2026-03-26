# frozen_string_literal: true

class CreateLinearTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :linear_tokens do |t|
      t.references :account, null: false, foreign_key: true
      t.references :created_by, null: true, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.text :token, null: false
      t.string :validation_status, null: false, default: "pending"
      t.string :validation_error
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :linear_tokens, [ :account_id, :name ], unique: true
    add_index :linear_tokens, :revoked_at
  end
end
