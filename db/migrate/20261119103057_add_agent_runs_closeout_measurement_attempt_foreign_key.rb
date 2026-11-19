# frozen_string_literal: true

class AddAgentRunsCloseoutMeasurementAttemptForeignKey < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :agent_runs, :trusted_measurement_attempts,
      column: :closeout_measurement_attempt_id, validate: false
  end
end
