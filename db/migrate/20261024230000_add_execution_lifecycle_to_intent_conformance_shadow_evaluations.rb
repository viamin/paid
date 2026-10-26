# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
      comment: "Cooperative stop request checked between reviewer cases; completed evidence is retained."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When cooperative reviewer execution stopped without fabricating remaining case results."
  end
end
