# frozen_string_literal: true

class AddAvailabilityChangedAtToRunnerStates < ActiveRecord::Migration[8.1]
  def change
    add_column :runner_states, :availability_changed_at, :datetime,
      comment: "When the circuit-breaker state or rate-limit window last changed. Distinct from updated_at, " \
        "which also bumps on routine quota-snapshot polling; used to detect genuine availability recovery."
  end
end
