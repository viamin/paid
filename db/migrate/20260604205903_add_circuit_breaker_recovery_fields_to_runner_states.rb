# frozen_string_literal: true

class AddCircuitBreakerRecoveryFieldsToRunnerStates < ActiveRecord::Migration[8.1]
  def change
    add_column :runner_states, :last_failure_at, :datetime,
      comment: "Timestamp of the most recent runner failure used to decay stale circuit-breaker failures."
    add_column :runner_states, :half_open_success_count, :integer, default: 0, null: false,
      comment: "Consecutive successes observed while the circuit is half-open."
    add_column :runner_states, :half_open_failure_count, :integer, default: 0, null: false,
      comment: "Consecutive failures observed while the circuit is half-open."
  end
end
