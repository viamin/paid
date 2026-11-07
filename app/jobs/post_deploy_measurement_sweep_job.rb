# frozen_string_literal: true

# Bounded recurring sweep for trusted post-deploy measurements: executes due
# and retry-eligible rows, recovers stale running rows, and re-requests
# evidence whose deployment generation or check version moved while the
# bound prerequisite is still active. Stops re-requesting evidence whose
# prerequisite was already released.
# @spec POST-DEPLOY-004 @spec POST-DEPLOY-009
class PostDeployMeasurementSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  self.max_attempts = 1

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: "post_deploy_measurement_sweep"
  )

  def perform
    TenantContext.with_system_access do
      execute_actionable
      refresh_stale_generations
    end
  end

  private

  def execute_actionable
    actionable_ids = PostDeployMeasurement.actionable.or(PostDeployMeasurement.stale_running).pluck(:id)
    actionable_ids.each { |id| PostDeployMeasurementJob.perform_later(id) }
  end

  # Terminal evidence is only current for its exact deployment revision and
  # check version: when the target moved and the bound prerequisite is still
  # active, request the current generation; when the prerequisite was
  # released (or no longer bound), leave history alone.
  def refresh_stale_generations
    PostDeployMeasurement.where(status: %w[passed failed]).distinct.pluck(:issue_id, :check_key).each do |issue_id, check_key|
      issue = Issue.find_by(id: issue_id)
      next unless issue

      latest = PostDeployMeasurement.latest_for(issue, check_key)
      next unless latest
      next if latest.released? || !prerequisite_active?(latest)

      target = PostDeployMeasurements::DeploymentTarget.resolve(issue)
      next unless target.deployed?
      next if latest.current_for?(target_revision: target.revision, check_version: current_version(check_key))

      PostDeployMeasurements::Request.call(
        issue: issue, check_key: check_key, criterion: latest.criterion,
        prerequisite_identity: latest.prerequisite_identity
      )
    end
  end

  def current_version(check_key)
    check = PostDeployMeasurements::Registry.find(check_key)
    check&.version || 0
  end

  def prerequisite_active?(measurement)
    return false if measurement.prerequisite_identity.blank?

    Notification.where(
      account: measurement.account,
      subject: measurement.issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      resolved_at: nil,
      dismissed_at: nil
    ).exists? && occurrence_present?(measurement)
  end

  def occurrence_present?(measurement)
    Notification.where(
      account: measurement.account,
      subject: measurement.issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      resolved_at: nil,
      dismissed_at: nil
    ).find_each do |notification|
      return true if PartialCloseouts::PrerequisiteOccurrences.for(notification)
        .any? { |candidate| candidate["identity"] == measurement.prerequisite_identity }
    end
    false
  end
end
