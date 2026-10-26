class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime,
      comment: "Cooperative stop signal checked between reviewer cases; collected runs remain intact."
    add_column :intent_conformance_shadow_evaluations, :execution_enqueued_at, :datetime,
      comment: "Most recent durable execution enqueue request, used by recovery to repair lost jobs."
    add_index :intent_conformance_shadow_evaluations, %i[status execution_enqueued_at],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
  end
end
