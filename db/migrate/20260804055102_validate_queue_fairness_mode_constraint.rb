# frozen_string_literal: true

class ValidateQueueFairnessModeConstraint < ActiveRecord::Migration[8.1]
  def change
    return unless check_constraint_exists?(:tenant_settings, name: "chk_queue_fairness_mode")

    validate_check_constraint :tenant_settings, name: "chk_queue_fairness_mode"
  end
end
