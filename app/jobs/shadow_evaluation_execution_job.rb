# frozen_string_literal: true

# Durable execution wrapper for a frozen Inbox shadow evaluation. The
# per-evaluation advisory lock in ExecuteReviewer remains the spend-dedup
# boundary; this job adds queue/retry/recovery semantics around it.
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class ShadowEvaluationExecutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :shadow_evaluation
  self.perform_timeout = IntentConformanceShadowEvaluation::EXECUTION_TIMEOUT
  good_job_control_concurrency_with(total_limit: 1,
    key: -> { "shadow_evaluation_#{arguments.second}" })
  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.mark_interrupted(error)
    job.notify_terminal_failure(error)
    raise error
  end
  discard_on ActiveRecord::RecordNotFound

  def perform(project_id, evaluation_id)
    evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)
    return unless evaluation.project_id == project_id
    return if evaluation.cancelled?
    return compile_report(evaluation) if evaluation.completed? && report_missing?(evaluation)
    return if evaluation.completed?

    result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
    return mark_interrupted(result.error) unless result.success?

    compile_report(evaluation)
  end

  def mark_interrupted(error)
    TenantContext.with_system_access do
      evaluation = IntentConformanceShadowEvaluation.find_by(id: arguments.second)
      return unless evaluation

      status = evaluation.runs.where.not(verdict: "not_evaluated").exists? ? "partial" : "failed"
      evaluation.update!(status:, last_failure_reason: failure_reason(error)) unless evaluation.cancelled? || evaluation.completed?
      IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if evaluation.runs.exists?
    end
  end

  def notification_project_id
    arguments.first
  end

  private

  def compile_report(evaluation)
    IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if evaluation.runs.exists?
  end

  def report_missing?(evaluation)
    evaluation.report.blank? || evaluation.report_markdown.blank?
  end

  def failure_reason(error)
    error.respond_to?(:message) ? error.message : error.to_s
  end

  def tenant_account
    TenantContext.with_system_access { Project.find_by(id: arguments.first)&.account }
  end
end
