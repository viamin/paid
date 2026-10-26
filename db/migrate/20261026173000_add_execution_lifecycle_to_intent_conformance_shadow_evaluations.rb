# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
      comment: "When an authorized operator requested cooperative cancellation between reviewer cases."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When execution entered its terminal cancelled state while retaining collected case evidence."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Last durable case-boundary progress time; recovery jobs resume this evaluation after interruption."
    add_column :intent_conformance_shadow_evaluations, :execution_attempts, :integer, null: false, default: 0,
      comment: "Number of worker attempts for this pinned evaluation identity."

    add_index :intent_conformance_shadow_evaluations, [ :status, :execution_heartbeat_at ],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
  end
end
