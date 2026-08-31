# frozen_string_literal: true

module Notifications
  class CheckProviderQuotasJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "notifications_check_provider_quotas"
    )

    def perform
      providers = Provider.includes(user: :provider_states).to_a
      Rules::ProviderQuotaExhausted.call(scope: providers)
    end
  end
end
