class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime
    add_column :intent_conformance_shadow_evaluations, :execution_job_id, :string
    change_column_comment :intent_conformance_shadow_evaluations, :status,
      "labeling → frozen → queued → running → partial | failed | cancelled | completed (see IntentConformanceShadowEvaluation::STATUSES)."
    add_index :intent_conformance_shadow_evaluations, :status, algorithm: :concurrently
    add_index :intent_conformance_shadow_evaluations, :execution_heartbeat_at, algorithm: :concurrently
  end
end
