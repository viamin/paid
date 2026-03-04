# frozen_string_literal: true

class CreateProviderStates < ActiveRecord::Migration[8.0]
  def change
    create_table :provider_states do |t|
      t.bigint :user_id, null: false
      t.string :provider_name, limit: 50, null: false
      t.datetime :rate_limited_until
      t.string :circuit_state, limit: 20, default: "closed", null: false
      t.integer :failure_count, default: 0, null: false
      t.datetime :circuit_opened_at

      t.timestamps
    end

    add_index :provider_states, %i[user_id provider_name], unique: true
    add_foreign_key :provider_states, :users, on_delete: :cascade
  end
end
