# frozen_string_literal: true

# Daily RDR-080 pilot sweep: records a cumulative `bounded_delivery` metric
# snapshot for every active enrollment, then consults the expansion guard. A
# guard pause condition (material delegated reversal or missing metric
# evidence) pauses the affected enrollment and returns the project to its
# conservative default pending human review.
#
# @spec PROJECT-DELEGATION-007
class DelegationPilotMetricsSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "delegation_pilot_metrics_sweep"
  )

  def perform
    TenantContext.with_system_access do
      DelegationPilotEnrollment.active.includes(project: { account: :tenant_setting }).find_each do |enrollment|
        sweep(enrollment)
      rescue StandardError => e
        Rails.logger.warn(
          message: "delegation_pilot_metrics.sweep_failed",
          project_id: enrollment.project_id,
          error_class: e.class.name,
          error_message: e.message
        )
      end
    end
  end

  private

  def sweep(enrollment)
    ProjectDelegation::RecordPilotMetrics.call(
      enrollment:,
      posture: "bounded_delivery",
      window_started_at: enrollment.enrolled_at,
      window_ended_at: Time.current
    )
    result = ProjectDelegation::ExpansionGuard.call(project: enrollment.project)
    return unless result.pause_reason

    ProjectDelegation::PauseExpansion.call(
      enrollment:,
      reason: result.pause_reason,
      evidence: { "reasons" => result.reasons.map(&:to_s) }
    )
  end
end
