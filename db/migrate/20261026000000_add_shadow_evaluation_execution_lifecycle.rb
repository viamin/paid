# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
# Asynchronous reviewer-execution lifecycle (#4642): the triggering request
# only enqueues, so the evaluation row itself carries the durable
# queued/running/partial/failed/cancelled/completed lifecycle. Status gains
# the queued/running/partial/cancelled values (validated on the model; the
# legacy synchronous `executing` writer remains valid for rows it already
# produced), and three timestamps drive the lifecycle: when execution was
# enqueued, the worker heartbeat refreshed before every case, and the
# cooperative cancellation request honored between cases.
class AddShadowEvaluationExecutionLifecycle < ActiveRecord::Migration[8.1]
  def up
    add_column :intent_conformance_shadow_evaluations, :execution_queued_at, :datetime,
      comment: "When reviewer execution was last enqueued for the background job; drives lost-job recovery."
    add_column :intent_conformance_shadow_evaluations, :execution_heartbeat_at, :datetime,
      comment: "Refreshed before every reviewer case so recovery can detect a dead worker."
    add_column :intent_conformance_shadow_evaluations, :cancel_requested_at, :datetime,
      comment: "Cooperative cancellation requested by an authorized operator; honored at start or between cases."

    change_column_comment :intent_conformance_shadow_evaluations, :status,
      "labeling → frozen → queued → running → completed | partial | failed | cancelled (legacy rows may hold the pre-async `executing` value; see IntentConformanceShadowEvaluation::STATUSES)."
  end

  def down
    change_column_comment :intent_conformance_shadow_evaluations, :status,
      "labeling → frozen → executing → completed | failed (see IntentConformanceShadowEvaluation::STATUSES)."
    remove_columns :intent_conformance_shadow_evaluations, :cancel_requested_at, :execution_heartbeat_at, :execution_queued_at
  end
end
