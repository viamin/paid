class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
      comment: "When an operator requested cooperative cancellation of reviewer execution."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Last durable reviewer-worker progress heartbeat for recovery of interrupted jobs."
  end
end
