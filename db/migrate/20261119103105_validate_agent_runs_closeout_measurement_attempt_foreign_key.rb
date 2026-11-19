# frozen_string_literal: true

class ValidateAgentRunsCloseoutMeasurementAttemptForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :agent_runs, :trusted_measurement_attempts,
      column: :closeout_measurement_attempt_id
  end
end
