# frozen_string_literal: true

class ExecutionResourceReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "execution_resource_reconciliation"
  )

  # @spec CONTAINER-RUNTIME-036
  def perform
    result = ExecutionRunners::ResourceReconciler.call

    Rails.logger.info(
      message: "execution_resources.reconciliation_complete",
      **result
    )
  end
end
