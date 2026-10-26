# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-007 @spec INTENT-CONFORMANCE-ROLLOUT-009
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :execution_requested_at, :datetime, if_not_exists: true, comment: "When an operator queued reviewer execution."
    add_column :intent_conformance_shadow_evaluations, :execution_started_at, :datetime, if_not_exists: true, comment: "When the queued worker began its current attempt."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime, if_not_exists: true, comment: "Most recent durable reviewer-case progress heartbeat."
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime, if_not_exists: true, comment: "Cooperative stop request checked between reviewer cases."
    add_index :intent_conformance_shadow_evaluations, %i[status execution_heartbeat_at],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
  end
end
