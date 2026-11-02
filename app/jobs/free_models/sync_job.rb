# frozen_string_literal: true

module FreeModels
  class SyncJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    self.good_job_labels = [ "free_models_sync" ]
    good_job_concurrency_rule(
      total_limit: 1,
      enqueue_limit: 1,
      label: "free_models_sync"
    )

    # @spec FREE-MODEL-SYNC-008
    def perform
      FreeModels::Sync.call
    end
  end
end
