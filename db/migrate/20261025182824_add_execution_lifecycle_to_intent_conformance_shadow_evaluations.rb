# frozen_string_literal: true

# Asynchronous reviewer-execution lifecycle (#4642): cooperative cancellation
# request, per-case execution heartbeat for stranded-worker recovery, and a
# bounded automatic-resume attempt counter. Extends the status vocabulary to
# queued/partial/cancelled (see IntentConformanceShadowEvaluation::STATUSES).
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:intent_conformance_shadow_evaluations, :cancel_requested_at)
      add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
        comment: "Set by an authorized cancellation; a running execution stops between cases and keeps recorded evidence."
    end
    unless column_exists?(:intent_conformance_shadow_evaluations, :execute_heartbeat_at)
      add_column :intent_conformance_shadow_evaluations, :execute_heartbeat_at, :datetime,
        comment: "Updated after each executed case; stale heartbeats with a free execution lock mean the worker died."
    end
    unless column_exists?(:intent_conformance_shadow_evaluations, :execution_attempts)
      add_column :intent_conformance_shadow_evaluations, :execution_attempts, :integer, null: false, default: 0,
        comment: "Enqueue count for this evaluation; bounds automatic recovery resumes."
    end
    change_column_comment :intent_conformance_shadow_evaluations, :status,
      "labeling → frozen → queued → executing → completed | partial | failed | cancelled (see IntentConformanceShadowEvaluation::STATUSES)."
  end

  def down
    change_column_comment :intent_conformance_shadow_evaluations, :status,
      "labeling → frozen → executing → completed | failed (see IntentConformanceShadowEvaluation::STATUSES)."
    remove_column :intent_conformance_shadow_evaluations, :execution_attempts if column_exists?(:intent_conformance_shadow_evaluations, :execution_attempts)
    remove_column :intent_conformance_shadow_evaluations, :execute_heartbeat_at if column_exists?(:intent_conformance_shadow_evaluations, :execute_heartbeat_at)
    remove_column :intent_conformance_shadow_evaluations, :cancel_requested_at if column_exists?(:intent_conformance_shadow_evaluations, :cancel_requested_at)
  end
end
