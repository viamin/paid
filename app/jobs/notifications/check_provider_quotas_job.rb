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
      Provider.includes(:user).find_each do |provider|
        Rules::ProviderQuotaExhausted.call(scope: provider)
      end
    end
  end
end
