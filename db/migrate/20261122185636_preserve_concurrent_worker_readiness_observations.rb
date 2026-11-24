# frozen_string_literal: true

class PreserveConcurrentWorkerReadinessObservations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    remove_index :worker_readiness_observations, :role, algorithm: :concurrently
    add_index :worker_readiness_observations, %i[role pid ready_at], unique: true,
      algorithm: :concurrently
  end
end
