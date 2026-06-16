# frozen_string_literal: true

class AddLastProbeRunIdToDispatchCircuitBreakers < ActiveRecord::Migration[8.1]
  def change
    add_column :dispatch_circuit_breakers, :last_probe_run_id, :bigint,
      null: true,
      comment: "Agent run dispatched as the half_open probe; only this run's outcome counts toward the breaker's half_open counters so stale in-flight runs from before the circuit opened cannot close or re-open the breaker"
  end
end
