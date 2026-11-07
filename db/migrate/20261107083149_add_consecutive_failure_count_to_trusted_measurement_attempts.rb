# frozen_string_literal: true

class AddConsecutiveFailureCountToTrustedMeasurementAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :trusted_measurement_attempts, :consecutive_failure_count, :integer, null: false, default: 0
  end
end
