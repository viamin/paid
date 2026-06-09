# frozen_string_literal: true

class AddMaxConcurrentCreatePrRunsToTenantSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_settings, :max_concurrent_create_pr_runs, :integer, default: 20, null: false,
      comment: "Account-level cap on concurrent create_pr agent runs to prevent success rate collapse at high concurrency"
  end
end
