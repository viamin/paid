# frozen_string_literal: true

# Executes one trusted post-deploy measurement under its own tenant context.
# The bounded sweep enqueues this job; retries and duplicate enqueues are
# serialized per measurement, and the executor itself is idempotent for a
# deployment generation.
# @spec POST-DEPLOY-009
class PostDeployMeasurementJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  self.max_attempts = 1

  good_job_control_concurrency_with(
    total_limit: 1,
    perform_limit: 1,
    key: -> { "post_deploy_measurement_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  def perform(measurement_id)
    TenantContext.with_system_access do
      measurement = PostDeployMeasurement.find_by(id: measurement_id)
      next unless measurement

      TenantContext.with(measurement.account) { PostDeployMeasurements::Execute.call(measurement:) }
    end
  end
end
