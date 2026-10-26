# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddAsyncLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :timestamp,
      comment: "Durable cooperative stop signal checked between reviewer cases."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :timestamp,
      comment: "When queued or running reviewer execution settled as cancelled."
  end
end
