# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :execution_requested_at, :datetime,
      comment: "When an authorized operator last queued this evaluation."
    add_column :intent_conformance_shadow_evaluations, :execution_cancelled_at, :datetime,
      comment: "When an authorized operator requested cooperative cancellation."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Last durable worker progress heartbeat; stale work may be safely resumed."

    add_index :intent_conformance_shadow_evaluations, %i[status execution_heartbeat_at],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
  end
end
