# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime,
      comment: "When an authorized operator requested cooperative cancellation between reviewer cases."
  end
end
