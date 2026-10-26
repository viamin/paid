# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :intent_conformance_shadow_evaluations, :execution_lease_expires_at, :datetime,
      comment: "Bounded worker lease; an expired lease permits a safe resume after worker loss."
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
      comment: "Operator stop request, checked cooperatively between reviewer cases."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When execution stopped without fabricating results for remaining cases."
    add_index :intent_conformance_shadow_evaluations, %i[status execution_lease_expires_at],
      name: "idx_shadow_evaluations_execution_recovery", algorithm: :concurrently
  end
end
