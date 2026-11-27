# frozen_string_literal: true

# @spec POSTGRESQL-PERSISTENCE-014
class ValidateDispatchCircuitBreakersLastProbeRunForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :dispatch_circuit_breakers, :agent_runs, column: :last_probe_run_id
  end
end
