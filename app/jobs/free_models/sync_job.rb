# frozen_string_literal: true

module FreeModels
  class SyncJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "free_models_sync"
    )

    # @spec FREE-MODEL-SYNC-008
    def perform
      FreeModels::Sync.call
    end
  end
end
