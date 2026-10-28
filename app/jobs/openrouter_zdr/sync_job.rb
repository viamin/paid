# frozen_string_literal: true

module OpenrouterZdr
  class SyncJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "openrouter_zdr_sync"
    )

    # @spec FREE-MODEL-SYNC-013
    def perform
      Sync.call
    end
  end
end
