# frozen_string_literal: true

module OpenrouterZdr
  class SyncJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    self.good_job_labels = [ "openrouter_zdr_sync" ]
    good_job_concurrency_rule(total_limit: 1, enqueue_limit: 1, label: "openrouter_zdr_sync")

    # @spec FREE-MODEL-SYNC-009
    def perform
      OpenrouterZdr::Sync.call
    end
  end
end
