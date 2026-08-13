# frozen_string_literal: true

class BackfillOrchestrationStrategies < ActiveRecord::Migration[8.1]
  def up
    OrchestrationStrategies::Seed.call
  end

  def down
    # Seeded system-default records (account_id IS NULL) are removed on rollback.
    # Account-level overrides are left in place.
    execute <<~SQL
      DELETE FROM orchestration_strategies WHERE account_id IS NULL
    SQL
  end
end
