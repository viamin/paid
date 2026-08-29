# frozen_string_literal: true

module Notifications
  class CheckRunnerQuotasJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "notifications_check_runner_quotas"
    )

    def perform
      runners = Runner.includes(user: :runner_states).to_a
      Rules::RunnerQuotaExhausted.call(scope: runners)
      Rules::RunnerSubscriptionAuthIneligible.call(scope: runners)
    end
  end
end
