# frozen_string_literal: true

class AddConfigurationNamespacesToTenantSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_settings, :provider_preferences, :jsonb, null: false, default: {}
    add_column :tenant_settings, :default_budgets, :jsonb, null: false, default: {}
    add_column :tenant_settings, :guardrails, :jsonb, null: false, default: {}
    add_column :tenant_settings, :quality_thresholds, :jsonb, null: false, default: {}
    add_column :tenant_settings, :agent_settings, :jsonb, null: false, default: {}
  end
end
