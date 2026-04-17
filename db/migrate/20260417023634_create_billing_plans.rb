# frozen_string_literal: true

class CreateBillingPlans < ActiveRecord::Migration[8.1]
  def change
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

    add_index :billing_plans, [ :account_id, :active ]
  end
end
