# frozen_string_literal: true

class AddEnvironmentToWorkerReadinessObservations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :worker_readiness_observations, :environment, :string,
      comment: "Rails environment of the worker process that published this observation."
    remove_index :worker_readiness_observations, %i[role pid ready_at], algorithm: :concurrently
    add_index :worker_readiness_observations, %i[environment role pid ready_at], unique: true,
      algorithm: :concurrently
  end
end
