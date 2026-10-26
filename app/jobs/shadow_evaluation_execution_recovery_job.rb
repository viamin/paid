# frozen_string_literal: true

# A worker killed before it can run its rescue path must not leave a costly
# evaluation presenting as queued/running forever. This bounded watchdog
# preserves recorded case evidence and leaves retry to the normal action.
# @spec INTENT-CONFORMANCE-ROLLOUT-009
class ShadowEvaluationExecutionRecoveryJob < ApplicationJob
  queue_as :maintenance
  discard_on ActiveRecord::RecordNotFound

  def perform(project_id, evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return unless evaluation.project_id == project_id && (evaluation.queued? || evaluation.running?)
    return if evaluation.execution_heartbeat_at&.>= 10.minutes.ago
    return if evaluation.execution_requested_at&.>= 10.minutes.ago

    evaluation.update!(status: "failed", last_failure_reason: "reviewer execution worker stopped before completion")
    compile_report(evaluation) if evaluation.runs.exists?
  end

  private

  def compile_report(evaluation)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation)
  rescue IntentConformance::ShadowEvaluationCorpus::MissingManifest => error
    Rails.logger.warn(message: "intent_conformance.shadow_evaluation_recovery_report_unavailable",
      shadow_evaluation_id: evaluation.id, error_class: error.class.name)
  end
end
