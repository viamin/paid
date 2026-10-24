# frozen_string_literal: true

class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime,
      comment: "Operator cancellation signal checked by the reviewer worker between corpus cases."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Last durable worker progress heartbeat; stale execution may be safely requeued."
    add_column :intent_conformance_shadow_evaluations, :execution_attempt, :integer, null: false, default: 0,
      comment: "Monotonic count of queued reviewer execution attempts for this evidence generation."
    change_column_comment :intent_conformance_shadow_evaluations, :status,
      from: "labeling → frozen → executing → completed | failed (see IntentConformanceShadowEvaluation::STATUSES).",
      to: "labeling → frozen → queued → running → completed | partial | failed | cancelled."
    add_index :intent_conformance_shadow_evaluations, %i[status execution_heartbeat_at],
      name: "idx_shadow_evaluations_execution_recovery",
      comment: "Bounds stale reviewer-worker recovery scans.",
      algorithm: :concurrently
  end

  def down
    if index_exists?(:intent_conformance_shadow_evaluations, name: "idx_shadow_evaluations_execution_recovery")
      remove_index :intent_conformance_shadow_evaluations, name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
    end
    change_column_comment :intent_conformance_shadow_evaluations, :status,
      from: "labeling → frozen → queued → running → completed | partial | failed | cancelled.",
      to: "labeling → frozen → executing → completed | failed (see IntentConformanceShadowEvaluation::STATUSES)."
    remove_column :intent_conformance_shadow_evaluations, :execution_attempt
    remove_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at
    remove_column :intent_conformance_shadow_evaluations, :cancellation_requested_at
  end
end
