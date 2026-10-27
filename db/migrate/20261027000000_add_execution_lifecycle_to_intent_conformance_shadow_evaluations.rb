# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-011
class AddExecutionLifecycleToIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  INTERRUPTED_REASON = "Legacy synchronous reviewer execution was interrupted before migration."
  STATUS_COMMENT = "labeling → frozen → queued → running → partial | failed | cancelled | completed " \
    "(see IntentConformanceShadowEvaluation::STATUSES)."

  def up
    add_column :intent_conformance_shadow_evaluations, :execution_enqueued_at, :datetime,
      comment: "When the authorized asynchronous reviewer execution was queued."
    add_column :intent_conformance_shadow_evaluations, :cancellation_requested_at, :datetime,
      comment: "Cooperative stop requested by an authorized operator; observed between reviewer cases."
    add_column :intent_conformance_shadow_evaluations, :cancelled_at, :datetime,
      comment: "When a queued or running execution stopped without fabricating remaining case results."
    change_column_comment :intent_conformance_shadow_evaluations, :status, STATUS_COMMENT

    safety_assured do
      execute <<~SQL.squish
        UPDATE intent_conformance_shadow_evaluations
        SET status = 'failed', last_failure_reason = #{connection.quote(INTERRUPTED_REASON)}
        WHERE status = 'executing'
      SQL
    end
  end

  def down
    safety_assured do
      execute <<~SQL.squish
        UPDATE intent_conformance_shadow_evaluations
        SET status = 'executing', last_failure_reason = NULL
        WHERE status = 'failed' AND last_failure_reason = #{connection.quote(INTERRUPTED_REASON)}
      SQL
    end

    change_column_comment :intent_conformance_shadow_evaluations, :status,
      "labeling → frozen → executing → completed | failed (see IntentConformanceShadowEvaluation::STATUSES)."
    remove_column :intent_conformance_shadow_evaluations, :cancelled_at
    remove_column :intent_conformance_shadow_evaluations, :cancellation_requested_at
    remove_column :intent_conformance_shadow_evaluations, :execution_enqueued_at
  end
end
