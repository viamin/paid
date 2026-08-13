# frozen_string_literal: true

class CreateBillingPlans < ActiveRecord::Migration[8.1]
  def up
    create_billing_plans unless table_exists?(:billing_plans)

    add_foreign_key :billing_plans, :accounts unless foreign_key_exists?(:billing_plans, :accounts)
    add_index :billing_plans, :account_id unless index_exists?(:billing_plans, :account_id)
    add_index :billing_plans, [ :account_id, :active ] unless index_exists?(:billing_plans, [ :account_id, :active ])
  end

  def down
    drop_table :billing_plans, if_exists: true
  end

  private

  def create_billing_plans
    create_table :billing_plans do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.string :billing_model, null: false, limit: 30
      t.integer :base_rate_cents, null: false, default: 0
      t.decimal :per_token_rate_cents, precision: 12, scale: 6, null: false, default: 0
      t.integer :per_run_rate_cents, null: false, default: 0
      t.integer :per_project_rate_cents, null: false, default: 0
      t.bigint :included_tokens, null: false, default: 0
      t.integer :included_runs, null: false, default: 0
      t.integer :included_projects, null: false, default: 0
      t.string :period_type, null: false, limit: 20
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
  end
end
