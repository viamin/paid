# frozen_string_literal: true

module Notifications
  class CheckRunnerQuotasJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    self.good_job_labels = [ "notifications_check_runner_quotas" ]
    good_job_concurrency_rule(
      total_limit: 1,
      enqueue_limit: 1,
      label: "notifications_check_runner_quotas"
    )

    def perform
      runners = Runner.includes(user: :runner_states).to_a
      Rules::RunnerQuotaExhausted.call(scope: runners)
      Rules::RunnerSubscriptionAuthIneligible.call(scope: runners)
    end
  end
end
