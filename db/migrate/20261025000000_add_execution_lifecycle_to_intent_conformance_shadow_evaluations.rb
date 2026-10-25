# frozen_string_literal: true

# Async reviewer-execution lifecycle for the RDR-067 shadow evaluation
# (#4642): the HTTP request only authorizes/enqueues an idempotent job, so
# the evaluation record itself carries the queued/running execution state,
# the between-cases worker heartbeat, and the operator cancellation request.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :execute_queued_at, :datetime,
      comment: "When reviewer execution was last enqueued (queued state claim)."
    add_column :intent_conformance_shadow_evaluations, :execute_heartbeat_at, :datetime,
      comment: "Worker heartbeat stamped after each corpus case; staleness drives interrupted-execution recovery."
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
      comment: "When an operator requested cancellation; honored between cases and before the job starts."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When cancellation took effect; collected evidence is preserved and never fabricated."
    add_index :intent_conformance_shadow_evaluations, %i[status execute_heartbeat_at],
      name: "idx_shadow_evaluations_recovery_lookup",
      comment: "Recovery sweep lookup for stale queued/running executions.",
      algorithm: :concurrently
  end
end
