# frozen_string_literal: true

class AddQueueFairnessModeToTenantSettings < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:tenant_settings, :queue_fairness_mode)
      add_column :tenant_settings, :queue_fairness_mode, :string,
        limit: 20,
        default: "fair_share",
        null: false,
        comment: "Account dequeue policy: fair_share (round-robin across projects) or strict_priority (global priority order)."
    end

    return if check_constraint_exists?(:tenant_settings, name: "chk_queue_fairness_mode")

    add_check_constraint :tenant_settings,
      "queue_fairness_mode IN ('fair_share', 'strict_priority')",
      name: "chk_queue_fairness_mode",
      validate: false
  end
end
