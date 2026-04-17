# frozen_string_literal: true

class CreateBillingPeriods < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_periods do |t|
      t.references :account, null: false, foreign_key: true
      t.references :billing_plan, null: false, foreign_key: true
      t.string :period_type, null: false, limit: 20
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :status, null: false, limit: 20, default: "open"
      t.integer :total_cost_cents, null: false, default: 0
      t.bigint :total_input_tokens, null: false, default: 0
      t.bigint :total_output_tokens, null: false, default: 0
      t.integer :total_runs, null: false, default: 0
      t.integer :total_compute_seconds, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :billing_periods, [ :account_id, :status ]
    add_index :billing_periods, [ :account_id, :starts_at, :ends_at ]
  end
end
