# frozen_string_literal: true

class ExecutionResourceReconciliationJob < ApplicationJob # @spec CONTAINER-RUNTIME-033
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  self.good_job_labels = [ "execution_resource_reconciliation" ]
  good_job_concurrency_rule(
    total_limit: 1,
    enqueue_limit: 1,
    label: "execution_resource_reconciliation"
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
