# frozen_string_literal: true

class CreateTenantSettings < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:tenant_settings)
      create_table :tenant_settings do |t|
        t.references :account, null: false, foreign_key: true, index: { unique: true }
        t.integer :max_concurrent_runs, null: false, default: 10
        t.integer :max_projects, null: false, default: 50
        t.integer :max_users, null: false, default: 25
        t.integer :max_tokens_per_run, null: false, default: 10_000_000
        t.integer :max_monthly_cost_cents
        t.text :allowed_provider_keys, array: true, default: []
        t.jsonb :features, null: false, default: {}
        t.timestamps
      end
    end
  end
end
