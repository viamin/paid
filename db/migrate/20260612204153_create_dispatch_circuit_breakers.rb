# frozen_string_literal: true

class CreateDispatchCircuitBreakers < ActiveRecord::Migration[8.1]
  def change
    create_table :dispatch_circuit_breakers, comment: "Account-level dispatch circuit breaker that halts scheduling when all providers fail simultaneously" do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true },
        comment: "Account this circuit breaker belongs to"
      t.string :circuit_state, null: false, default: "closed", limit: 20,
        comment: "Current circuit state: closed, open, or half_open"
      t.datetime :circuit_opened_at,
        comment: "When the circuit was last opened"
      t.datetime :last_probe_at,
        comment: "When the last probe run was dispatched during half_open"
      t.integer :half_open_success_count, null: false, default: 0,
        comment: "Consecutive successes in half_open state"
      t.integer :half_open_failure_count, null: false, default: 0,
        comment: "Consecutive failures in half_open state"
      t.jsonb :trip_metadata, null: false, default: {},
        comment: "Failure statistics at the time the circuit was tripped"
      t.datetime :last_evaluated_at,
        comment: "When the circuit was last evaluated"

      t.timestamps
    end
  end
end
