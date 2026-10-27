# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :intent_conformance_shadow_evaluations, :execution_enqueued_at, :datetime,
      comment: "When the authorized asynchronous reviewer execution was queued."
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime,
      comment: "Cooperative stop requested by an authorized operator; observed between reviewer cases."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When a queued or running execution stopped without fabricating remaining case results."
  end
end
