# frozen_string_literal: true

# Generated migration command could not boot in this environment because its
# DATABASE_URL role has BYPASSRLS; this is the Rails-generator-equivalent
# migration kept intentionally small for the evaluation lifecycle.
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :intent_conformance_shadow_evaluations, :execution_requested_at, :datetime
    add_column :intent_conformance_shadow_evaluations, :execution_cancelled_at, :datetime
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime
  end
end
