# frozen_string_literal: true

class CreateBillingPeriods < ActiveRecord::Migration[8.1]
  def up
    create_billing_periods unless table_exists?(:billing_periods)

    add_foreign_key :billing_periods, :accounts unless foreign_key_exists?(:billing_periods, :accounts)
    add_foreign_key :billing_periods, :billing_plans unless foreign_key_exists?(:billing_periods, :billing_plans)
    add_index :billing_periods, :account_id unless index_exists?(:billing_periods, :account_id)
    add_index :billing_periods, :billing_plan_id unless index_exists?(:billing_periods, :billing_plan_id)
    add_index :billing_periods, [ :account_id, :status ] unless index_exists?(:billing_periods, [ :account_id, :status ])
    add_index :billing_periods, [ :account_id, :starts_at, :ends_at ] unless index_exists?(:billing_periods, [ :account_id, :starts_at, :ends_at ])
  end

  def down
    drop_table :billing_periods, if_exists: true
  end

  private

  def create_billing_periods
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
  end
end
