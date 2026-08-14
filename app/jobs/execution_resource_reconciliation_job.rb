# frozen_string_literal: true

class ExecutionResourceReconciliationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "execution_resource_reconciliation"
  )

  def perform
    result = ExecutionResources::Reconcile.new.call

    Rails.logger.info(
      message: "container_manager.execution_resource_reconciliation_complete",
      checked: result.checked,
      adopted: result.adopted,
      cleaned: result.cleaned,
      failures: result.failures,
      reduced_confidence: result.reduced_confidence
    )
  end
end
