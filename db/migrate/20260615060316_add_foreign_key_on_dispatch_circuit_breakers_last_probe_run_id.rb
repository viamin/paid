# frozen_string_literal: true

class AddForeignKeyOnDispatchCircuitBreakersLastProbeRunId < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :dispatch_circuit_breakers, :agent_runs,
      column: :last_probe_run_id,
      on_delete: :nullify,
      validate: false
  end
end
