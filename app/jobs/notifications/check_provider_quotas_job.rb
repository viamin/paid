# frozen_string_literal: true

module Notifications
  class CheckProviderQuotasJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    self.good_job_labels = [ "notifications_check_provider_quotas" ]
    good_job_concurrency_rule(
      total_limit: 1,
      enqueue_limit: 1,
      label: "notifications_check_provider_quotas"
    )

    def perform
      providers = Provider.includes(user: :provider_states).to_a
      Rules::ProviderQuotaExhausted.call(scope: providers)
    end
  end
end
