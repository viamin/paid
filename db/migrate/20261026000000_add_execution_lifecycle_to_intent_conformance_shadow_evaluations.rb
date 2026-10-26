# frozen_string_literal: true

class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :execution_cancel_requested, :boolean, default: false, null: false,
      comment: "Cooperative stop signal checked between paid reviewer cases."
    add_column :intent_conformance_shadow_evaluations, :execution_enqueued_at, :datetime,
      comment: "When the durable reviewer execution job was last requested."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Worker heartbeat used to recover an interrupted execution."
    add_index :intent_conformance_shadow_evaluations, [ :status, :execution_heartbeat_at ],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
  end
end
