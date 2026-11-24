# frozen_string_literal: true

# Durable readiness observations published by the owning Temporal worker
# processes. System-wide operational metadata (PID, boot time, booted
# revision, latest heartbeat), not tenant-owned data.
class CreateWorkerReadinessObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :worker_readiness_observations, comment: "Per-role Temporal worker readiness heartbeats; system-wide, not tenant-owned." do |t|
      t.string :role, null: false
      t.integer :pid, null: false
      t.string :revision
      t.datetime :ready_at, null: false, comment: "When this worker process finished booting."
      t.datetime :heartbeat_at, null: false, comment: "When the live process last published its readiness identity."
      t.timestamps
    end
    add_index :worker_readiness_observations, :role, unique: true
  end
end
